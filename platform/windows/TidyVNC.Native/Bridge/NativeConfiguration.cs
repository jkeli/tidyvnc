// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>One parameter assignment from a configuration source (position: line, argument or value index).</summary>
public sealed record NativeConfigAssignment(string Name, string Value, NativeOptionSource Source, uint Position);

/// <summary>An effective, canonical value with its provenance; Dormant values are kept but inactive.</summary>
public sealed record NativeConfigValue(string Name, string Value, NativeOptionSource Source, uint Position, bool Dormant);

public enum NativeConfigNoteKind : uint { DotWhenNoCursor = 1, FullScreenAllMonitors = 2 }

/// <summary>A deprecated flag set Parameter (from Source at Position).</summary>
public sealed record NativeConfigNote(NativeConfigNoteKind Kind, string Parameter, NativeOptionSource Source, uint Position);

public sealed record NativeConfigResolution(IReadOnlyList<NativeConfigValue> Values, IReadOnlyList<NativeConfigNote> Notes)
{
    public NativeConfigValue? this[string name] => Values.FirstOrDefault(v => v.Name == name);
}

public sealed class NativeConfigFailure : Exception
{
    public enum Problem : uint { UnknownParameter = 1, InvalidValue = 2, InvalidSource = 3, Unavailable = 4, TooMany = 5 }
    public Problem Reason { get; }
    /// <summary>One-based index of the failing assignment, or zero.</summary>
    public uint Index { get; }
    public NativeConfigFailure(Problem reason, uint index) : base($"Configuration assignment {index}: {reason}")
    {
        Reason = reason; Index = index;
    }
}

/// <summary>
/// The shared configuration precedence (tidyvnc_config_resolve): compiled,
/// app defaults, profile, command line, explicit file; deprecated migrations
/// after every layer; per-value provenance.
/// </summary>
public static unsafe class NativeConfiguration
{
    public static NativeConfigResolution Resolve(IReadOnlyList<NativeConfigAssignment> assignments)
    {
        var encoded = assignments.Select(a => (Encoding.UTF8.GetBytes(a.Name), Encoding.UTF8.GetBytes(a.Value))).ToArray();
        var pins = new List<System.Runtime.InteropServices.GCHandle>();
        try
        {
            var input = new tidyvnc_config_assignment[encoded.Length];
            for (var i = 0; i < encoded.Length; i++)
            {
                var name = System.Runtime.InteropServices.GCHandle.Alloc(encoded[i].Item1, System.Runtime.InteropServices.GCHandleType.Pinned);
                var value = System.Runtime.InteropServices.GCHandle.Alloc(encoded[i].Item2, System.Runtime.InteropServices.GCHandleType.Pinned);
                pins.Add(name); pins.Add(value);
                input[i] = new tidyvnc_config_assignment
                {
                    name = AbiText.Span((byte*)name.AddrOfPinnedObject(), encoded[i].Item1.Length),
                    value = AbiText.Span((byte*)value.AddrOfPinnedObject(), encoded[i].Item2.Length),
                    source = (uint)assignments[i].Source, position = assignments[i].Position,
                };
            }
            var error = Abi.Init<tidyvnc_error>();
            ulong raw = 0;
            uint status;
            fixed (tidyvnc_config_assignment* data = input)
                status = NativeMethods.tidyvnc_config_resolve(data, (uint)input.Length, &raw, &error);
            if (status != Tidyvnc.TIDYVNC_OK)
            {
                if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_CONFIG) throw new NativeConfigFailure((NativeConfigFailure.Problem)(error.detail & 0xff), error.detail >> 8);
                throw new NativeError(error);
            }
            using var owner = NativeHandle.Adopt(raw);
            var info = Abi.Init<tidyvnc_config_info>();
            Abi.Check(NativeMethods.tidyvnc_config_get(owner.Raw, &info, &error), &error);
            var values = new List<NativeConfigValue>();
            for (var i = 0u; i < info.value_count; i++)
            {
                var value = Abi.Init<tidyvnc_config_value>();
                Abi.Check(NativeMethods.tidyvnc_config_value_at(owner.Raw, i, &value, &error), &error);
                values.Add(new NativeConfigValue(AbiText.Fixed(value.name, 64),
                    value.value.length == 0 ? "" : Encoding.UTF8.GetString(value.value.data, checked((int)value.value.length)),
                    (NativeOptionSource)value.source, value.position, value.dormant != 0));
            }
            var notes = new List<NativeConfigNote>();
            for (var i = 0u; i < info.note_count; i++)
            {
                var note = Abi.Init<tidyvnc_config_note>();
                Abi.Check(NativeMethods.tidyvnc_config_note_at(owner.Raw, i, &note, &error), &error);
                notes.Add(new NativeConfigNote((NativeConfigNoteKind)note.kind, AbiText.Fixed(note.parameter, 64), (NativeOptionSource)note.source, note.position));
            }
            return new NativeConfigResolution(values, notes);
        }
        finally
        {
            foreach (var pin in pins) pin.Free();
        }
    }
}
