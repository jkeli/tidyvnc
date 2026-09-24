// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeEncodingOption : uint
{
    AutoSelect = 0, FullColor, LowColorLevel, Preferred, CustomCompression, Compression, NoJpeg, Quality,
}

public readonly record struct NativeEncodingAssignment(string Name, string Value);

public sealed record NativeEncodingSchema(NativeEncodingOption Id, NativeEncodingSchema.SchemaKind Kind, string Name, string Alias,
                                          string DefaultValue, int Minimum, int Maximum, bool Persistent, bool Live)
{
    public enum SchemaKind : uint { Boolean = 0, Integer, Enumeration }
}

public sealed record NativeEncodingChoice(string Name, int WireEncoding, bool Available);

public readonly record struct NativeEncodingValue(string Value, NativeOptionSource Source);

public enum NativeEncodingProblem : uint { UnknownOption = 1, InvalidValue, Unavailable, TooLong }

/// <summary>An immutable encoding option snapshot owned by the core (NativeEncodingOptions).</summary>
public sealed class NativeEncodingOptions : IDisposable
{
    internal NativeHandle Handle { get; }

    internal NativeEncodingOptions(NativeHandle handle) => Handle = handle;

    public NativeEncodingOptions(IReadOnlyList<NativeEncodingAssignment>? patch = null,
                                 NativeOptionSource source = NativeOptionSource.Session)
        : this(Create(null, patch ?? [], source)) { }

    private static unsafe NativeHandle Create(NativeEncodingOptions? baseline, IReadOnlyList<NativeEncodingAssignment> patch,
                                              NativeOptionSource source)
    {
        if (patch.Count > 256) throw new NativeError(NativeStatus.ResourceLimit, "Too many encoding assignments");
        var names = patch.Select(item => AbiText.Utf8(item.Name)).ToArray();
        var values = patch.Select(item => AbiText.Utf8(item.Value)).ToArray();
        if (names.Any(n => n.Length > 128) || values.Any(v => v.Length > 128))
            throw new NativeError(NativeStatus.ResourceLimit, "Encoding assignment exceeds its byte limit");
        var handles = new System.Runtime.InteropServices.GCHandle[names.Length * 2];
        try
        {
            var assignments = new tidyvnc_encoding_assignment[names.Length];
            for (var i = 0; i < names.Length; i++)
            {
                handles[2 * i] = System.Runtime.InteropServices.GCHandle.Alloc(names[i], System.Runtime.InteropServices.GCHandleType.Pinned);
                handles[2 * i + 1] = System.Runtime.InteropServices.GCHandle.Alloc(values[i], System.Runtime.InteropServices.GCHandleType.Pinned);
                assignments[i].name = AbiText.Span((byte*)handles[2 * i].AddrOfPinnedObject(), names[i].Length);
                assignments[i].value = AbiText.Span((byte*)handles[2 * i + 1].AddrOfPinnedObject(), values[i].Length);
            }
            var error = Abi.Init<tidyvnc_error>();
            ulong raw = 0;
            fixed (tidyvnc_encoding_assignment* input = assignments)
                Abi.Check(NativeMethods.tidyvnc_encoding_create(baseline?.Handle.Raw ?? 0, input, (uint)assignments.Length,
                    (uint)source, &raw, &error), &error);
            return NativeHandle.Adopt(raw);
        }
        finally
        {
            foreach (var pinned in handles) if (pinned.IsAllocated) pinned.Free();
        }
    }

    public NativeEncodingOptions Applying(IReadOnlyList<NativeEncodingAssignment> patch, NativeOptionSource source)
        => new(Create(this, patch, source));

    public unsafe NativeEncodingValue Value(NativeEncodingOption option)
    {
        var result = Abi.Init<tidyvnc_encoding_value>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_encoding_get(Handle.Raw, (uint)option, &result, &error), &error);
        if (!Enum.IsDefined((NativeOptionSource)result.source)) throw new NativeError(NativeStatus.Unsupported, "Unknown option source");
        return new NativeEncodingValue(AbiText.Fixed(result.value, 32), (NativeOptionSource)result.source);
    }

    public static unsafe IReadOnlyList<NativeEncodingSchema> Schema()
    {
        var result = new List<NativeEncodingSchema>();
        var error = Abi.Init<tidyvnc_error>();
        for (uint index = 0; index < 256; index++)
        {
            var value = Abi.Init<tidyvnc_encoding_schema>();
            if (Abi.Check(NativeMethods.tidyvnc_encoding_schema_at(index, &value, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.NoChange)
                return result;
            if (!Enum.IsDefined((NativeEncodingOption)value.id) || !Enum.IsDefined((NativeEncodingSchema.SchemaKind)value.type))
                throw new NativeError(NativeStatus.Unsupported, "Unknown encoding schema entry");
            result.Add(new NativeEncodingSchema((NativeEncodingOption)value.id, (NativeEncodingSchema.SchemaKind)value.type,
                AbiText.Fixed(value.name, 32), AbiText.Fixed(value.alias, 32), AbiText.Fixed(value.default_value, 32),
                value.minimum, value.maximum, value.persistent != 0, value.live != 0));
        }
        throw new NativeError(NativeStatus.ResourceLimit, "Encoding schema exceeds its entry limit");
    }

    public static unsafe IReadOnlyList<NativeEncodingChoice> Choices()
    {
        var result = new List<NativeEncodingChoice>();
        var error = Abi.Init<tidyvnc_error>();
        for (uint index = 0; index < 256; index++)
        {
            var value = Abi.Init<tidyvnc_encoding_choice>();
            if (Abi.Check(NativeMethods.tidyvnc_encoding_choice_at(index, &value, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.NoChange)
                return result;
            result.Add(new NativeEncodingChoice(AbiText.Fixed(value.name, 32), value.wire_encoding, value.available != 0));
        }
        throw new NativeError(NativeStatus.ResourceLimit, "Encoding choices exceed their entry limit");
    }

    public void Dispose() => Handle.Dispose();
}

public static class NativeEncodingErrors
{
    public static NativeEncodingProblem? EncodingProblem(this NativeError error)
        => error.Domain == Tidyvnc.TIDYVNC_DOMAIN_ENCODING && Enum.IsDefined((NativeEncodingProblem)(error.Detail & 0xffff))
            ? (NativeEncodingProblem)(error.Detail & 0xffff) : null;

    public static NativeEncodingOption? EncodingOption(this NativeError error)
        => error.Domain == Tidyvnc.TIDYVNC_DOMAIN_ENCODING && error.Detail >> 16 > 0
            ? (NativeEncodingOption)((error.Detail >> 16) - 1) : null;
}
