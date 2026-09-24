// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeImportNoticeKind : uint { Excluded = 1, Unknown = 2, PlatformOnly = 3 }

/// <summary>A source entry that will not be imported; Name is as written, never a value.</summary>
public sealed record NativeImportNotice(uint Line, string Name, NativeImportNoticeKind Kind);

/// <summary>A canonical, validated preference assignment from the source (file line or value position).</summary>
public sealed record NativeImportAssignment(string Name, string Value, uint Line);

public sealed record NativeDefaultsProjection(IReadOnlyList<NativeImportAssignment> Assignments, IReadOnlyList<NativeImportNotice> Notices);

public sealed record NativeHistoryProjection(IReadOnlyList<string> Endpoints, uint Duplicates, uint OmittedOlder)
{
    public bool RequiresOmissionReview => Duplicates != 0 || OmittedOlder != 0;
}

public sealed class NativeImportFailure : Exception
{
    public enum Problem : uint { Unrepresentable = 1, TooLarge = 2, InvalidText = 3, LineTooLong = 4, TooManyEntries = 5 }
    public Problem Reason { get; }
    public uint Line { get; }
    public NativeImportFailure(Problem reason, uint line) : base(line == 0 ? $"Import source: {reason}" : $"Import source line {line}: {reason}")
    {
        Reason = reason; Line = line;
    }
}

/// <summary>
/// The first step of importing the retained viewer's defaults or history
/// (tidyvnc_import_defaults/_history): allow-list, exclusions and validation,
/// from file bytes or from registry values. Nothing is read or written here.
/// </summary>
public static unsafe class NativeImport
{
    public static NativeDefaultsProjection DefaultsFromFile(ReadOnlySpan<byte> file) => Defaults(file, true, []);
    public static NativeDefaultsProjection DefaultsFromValues(IReadOnlyList<(string Name, string Value)> values) => Defaults([], false, values);
    public static NativeHistoryProjection HistoryFromFile(ReadOnlySpan<byte> file) => History(file, true, []);
    public static NativeHistoryProjection HistoryFromValues(IReadOnlyList<string> values) => History([], false, values);

    private static void Check(uint status, tidyvnc_error* error)
    {
        if (status == Tidyvnc.TIDYVNC_OK) return;
        if (error->domain == Tidyvnc.TIDYVNC_DOMAIN_IMPORT) throw new NativeImportFailure((NativeImportFailure.Problem)(error->detail & 0xff), error->detail >> 8);
        throw new NativeError(*error);
    }

    private static string Text(tidyvnc_bytes value) => value.length == 0 ? "" : Encoding.UTF8.GetString(value.data, checked((int)value.length));

    private static NativeDefaultsProjection Defaults(ReadOnlySpan<byte> file, bool fromFile, IReadOnlyList<(string Name, string Value)> values)
    {
        var encoded = values.Select(v => (Encoding.UTF8.GetBytes(v.Name), Encoding.UTF8.GetBytes(v.Value))).ToArray();
        var pins = new List<System.Runtime.InteropServices.GCHandle>();
        try
        {
            var input = new tidyvnc_import_value[encoded.Length];
            for (var i = 0; i < encoded.Length; i++)
            {
                var name = System.Runtime.InteropServices.GCHandle.Alloc(encoded[i].Item1, System.Runtime.InteropServices.GCHandleType.Pinned);
                var value = System.Runtime.InteropServices.GCHandle.Alloc(encoded[i].Item2, System.Runtime.InteropServices.GCHandleType.Pinned);
                pins.Add(name); pins.Add(value);
                input[i] = new tidyvnc_import_value
                {
                    name = NativeText.Span((byte*)name.AddrOfPinnedObject(), encoded[i].Item1.Length),
                    value = NativeText.Span((byte*)value.AddrOfPinnedObject(), encoded[i].Item2.Length),
                };
            }
            var error = Abi.Init<tidyvnc_error>();
            ulong raw = 0;
            byte empty = 0;
            fixed (byte* f = file) fixed (tidyvnc_import_value* v = input)
            {
                var source = fromFile ? NativeText.Span(f == null ? &empty : f, file.Length) : default;
                Check(NativeMethods.tidyvnc_import_defaults(source, v, (uint)input.Length, &raw, &error), &error);
            }
            using var owner = NativeHandle.Adopt(raw);
            var info = Abi.Init<tidyvnc_import_info>();
            Abi.Check(NativeMethods.tidyvnc_import_defaults_get(owner.Raw, &info, &error), &error);
            var assignments = new List<NativeImportAssignment>();
            for (var i = 0u; i < info.assignment_count; i++)
            {
                var value = Abi.Init<tidyvnc_import_assignment>();
                Abi.Check(NativeMethods.tidyvnc_import_assignment_at(owner.Raw, i, &value, &error), &error);
                assignments.Add(new NativeImportAssignment(NativeText.Fixed(value.name, 64), Text(value.value), value.line));
            }
            var notices = new List<NativeImportNotice>();
            for (var i = 0u; i < info.notice_count; i++)
            {
                var value = Abi.Init<tidyvnc_import_notice>();
                Abi.Check(NativeMethods.tidyvnc_import_notice_at(owner.Raw, i, &value, &error), &error);
                notices.Add(new NativeImportNotice(value.line, Text(value.name), (NativeImportNoticeKind)value.kind));
            }
            return new NativeDefaultsProjection(assignments, notices);
        }
        finally
        {
            foreach (var pin in pins) pin.Free();
        }
    }

    private static NativeHistoryProjection History(ReadOnlySpan<byte> file, bool fromFile, IReadOnlyList<string> values)
    {
        var encoded = values.Select(Encoding.UTF8.GetBytes).ToArray();
        var pins = encoded.Select(e => System.Runtime.InteropServices.GCHandle.Alloc(e, System.Runtime.InteropServices.GCHandleType.Pinned)).ToList();
        try
        {
            var input = new tidyvnc_bytes[encoded.Length];
            for (var i = 0; i < input.Length; i++) input[i] = NativeText.Span((byte*)pins[i].AddrOfPinnedObject(), encoded[i].Length);
            var error = Abi.Init<tidyvnc_error>();
            ulong raw = 0;
            byte empty = 0;
            fixed (byte* f = file) fixed (tidyvnc_bytes* v = input)
            {
                var source = fromFile ? NativeText.Span(f == null ? &empty : f, file.Length) : default;
                Check(NativeMethods.tidyvnc_import_history(source, v, (uint)input.Length, &raw, &error), &error);
            }
            using var owner = NativeHandle.Adopt(raw);
            var info = Abi.Init<tidyvnc_import_history_info>();
            Abi.Check(NativeMethods.tidyvnc_import_history_get(owner.Raw, &info, &error), &error);
            var endpoints = new List<string>();
            for (var i = 0; i < info.count; i++) endpoints.Add(Text(info.endpoints[i]));
            return new NativeHistoryProjection(endpoints, info.duplicates, info.omitted_older);
        }
        finally
        {
            foreach (var pin in pins) pin.Free();
        }
    }
}
