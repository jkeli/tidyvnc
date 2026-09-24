// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>tidyvnc document error reasons (NativeDocumentProblem in Swift).</summary>
public enum NativeDocumentProblem : uint
{
    Empty = 1, InvalidHeader, NullByte, LineTooLong, InvalidAssignment, InvalidEscape, TooLarge, TooManyEntries, InvalidExportName,
    InvalidText, InvalidIndex, InvalidValue, Unavailable,
}

/// <summary>A connection-file failure with its one-based line (zero when no line applies). Never carries file text.</summary>
public sealed class NativeDocumentFailure(NativeDocumentProblem problem, uint line) : Exception(line == 0 ? $"Connection file: {problem}" : $"Connection file line {line}: {problem}")
{
    public NativeDocumentProblem Problem { get; } = problem;
    public uint Line { get; } = line;
}

public sealed record NativeDocumentAssignment(string Name, string Value);

public sealed record NativeDocumentEntry(string Name, string EncodedValue, uint Line);

/// <summary>
/// A parsed .tidyvnc/.tigervnc connection file (tidyvnc_document_*;
/// NativeConnectionDocument on macOS). Syntax only: nothing is applied, read
/// or authorized. Invalid UTF-8 is rejected, never replaced.
/// </summary>
public sealed unsafe class NativeConnectionDocument : IDisposable
{
    public const int MaximumBytes = 1_048_576;
    public const int MaximumEntries = 4096;
    private static readonly UTF8Encoding Strict = new(false, true);

    private readonly NativeHandle handle;

    public bool IsLegacy { get; }
    public IReadOnlyList<NativeDocumentEntry> Entries { get; }

    private static NativeStatus Call(uint code, tidyvnc_error* error, NativeStatus allowed = NativeStatus.Ok)
    {
        var status = (NativeStatus)code;
        if (status == NativeStatus.Ok || status == allowed) return status;
        if (error->domain == Tidyvnc.TIDYVNC_DOMAIN_DOCUMENT && Enum.IsDefined((NativeDocumentProblem)(error->detail & 0xff)))
            throw new NativeDocumentFailure((NativeDocumentProblem)(error->detail & 0xff), error->detail >> 8);
        throw new NativeError(*error);
    }

    private static string Text(byte* bytes, int capacity, uint line)
    {
        var length = 0;
        while (length < capacity && bytes[length] != 0) length++;
        try { return Strict.GetString(bytes, length); }
        catch (DecoderFallbackException) { throw new NativeDocumentFailure(NativeDocumentProblem.InvalidText, line); }
    }

    public NativeConnectionDocument(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaximumBytes) throw new NativeDocumentFailure(NativeDocumentProblem.TooLarge, 0);
        try { _ = Strict.GetCharCount(data); }
        catch (DecoderFallbackException) { throw new NativeDocumentFailure(NativeDocumentProblem.InvalidText, 0); }
        var error = Abi.Init<tidyvnc_error>();
        ulong raw = 0;
        fixed (byte* bytes = data) Call(NativeMethods.tidyvnc_document_parse(AbiText.Span(bytes, data.Length), &raw, &error), &error);
        handle = NativeHandle.Adopt(raw);
        try
        {
            var info = Abi.Init<tidyvnc_document_info>();
            Call(NativeMethods.tidyvnc_document_get(handle.Raw, &info, &error), &error);
            if (info.count > MaximumEntries || info.legacy_header > 1) throw new NativeError(NativeStatus.Unsupported, "Unsupported connection-file metadata");
            var entries = new NativeDocumentEntry[info.count];
            for (uint index = 0; index < info.count; index++)
            {
                var entry = Abi.Init<tidyvnc_document_entry>();
                Call(NativeMethods.tidyvnc_document_entry_at(handle.Raw, index, 0, &entry, &error), &error);
                entries[index] = new NativeDocumentEntry(Text(entry.name, 255, entry.line), Text(entry.value, 256, entry.line), entry.line);
            }
            IsLegacy = info.legacy_header != 0;
            Entries = entries;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public string DecodedValue(int index)
    {
        if ((uint)index >= (uint)Entries.Count) throw new NativeDocumentFailure(NativeDocumentProblem.InvalidIndex, 0);
        var error = Abi.Init<tidyvnc_error>();
        var entry = Abi.Init<tidyvnc_document_entry>();
        Call(NativeMethods.tidyvnc_document_entry_at(handle.Raw, (uint)index, 1, &entry, &error), &error);
        return Text(entry.value, 256, entry.line);
    }

    /// <summary>The canonical option for a known field; null for unknown names.</summary>
    public NativeDocumentAssignment? ValidatedOption(int index)
    {
        if ((uint)index >= (uint)Entries.Count) throw new NativeDocumentFailure(NativeDocumentProblem.InvalidIndex, 0);
        var error = Abi.Init<tidyvnc_error>();
        var entry = Abi.Init<tidyvnc_document_entry>();
        if (Call(NativeMethods.tidyvnc_document_option_at(handle.Raw, (uint)index, &entry, &error), &error, NativeStatus.NoChange) == NativeStatus.NoChange)
            return null;
        return new NativeDocumentAssignment(Text(entry.name, 255, entry.line), Text(entry.value, 256, entry.line));
    }

    /// <summary>Canonical current header, names and LF endings; only the shared export catalog.</summary>
    public static byte[] Serialize(IReadOnlyList<NativeDocumentAssignment> fields)
    {
        if (fields.Count > MaximumEntries) throw new NativeDocumentFailure(NativeDocumentProblem.TooManyEntries, 0);
        var names = new byte[fields.Count][];
        var values = new byte[fields.Count][];
        for (var i = 0; i < fields.Count; i++)
        {
            names[i] = Encoding.UTF8.GetBytes(fields[i].Name);
            values[i] = Encoding.UTF8.GetBytes(fields[i].Value);
            if (names[i].Length > 255 || values[i].Length > 255) throw new NativeDocumentFailure(NativeDocumentProblem.LineTooLong, 0);
        }
        var handles = new List<System.Runtime.InteropServices.GCHandle>();
        try
        {
            var assignments = new tidyvnc_document_assignment[fields.Count];
            for (var i = 0; i < fields.Count; i++)
            {
                var name = System.Runtime.InteropServices.GCHandle.Alloc(names[i], System.Runtime.InteropServices.GCHandleType.Pinned);
                handles.Add(name);
                var value = System.Runtime.InteropServices.GCHandle.Alloc(values[i], System.Runtime.InteropServices.GCHandleType.Pinned);
                handles.Add(value);
                assignments[i] = new tidyvnc_document_assignment
                {
                    name = AbiText.Span((byte*)name.AddrOfPinnedObject(), names[i].Length),
                    value = AbiText.Span((byte*)value.AddrOfPinnedObject(), values[i].Length),
                };
            }
            var error = Abi.Init<tidyvnc_error>();
            ulong length = 0;
            fixed (tidyvnc_document_assignment* input = assignments)
            {
                Call(NativeMethods.tidyvnc_document_serialize(input, (uint)assignments.Length, default, &length, &error), &error);
                if (length > MaximumBytes) throw new NativeDocumentFailure(NativeDocumentProblem.TooLarge, 0);
                var output = new byte[length];
                fixed (byte* o = output)
                {
                    var written = length;
                    Call(NativeMethods.tidyvnc_document_serialize(input, (uint)assignments.Length,
                        new tidyvnc_mutable_bytes { data = o, length = (ulong)output.Length }, &written, &error), &error);
                    if (written != (ulong)output.Length) throw new NativeError(NativeStatus.InternalFailure, "Connection-file export size changed");
                }
                return output;
            }
        }
        finally
        {
            foreach (var pinned in handles) pinned.Free();
        }
    }

    public void Dispose() => handle.Dispose();
    public override string ToString() => "NativeConnectionDocument(<redacted>)";
}
