// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.CompilerServices;
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>tidyvnc_status values (NativeValues.swift NativeStatus).</summary>
public enum NativeStatus : uint
{
    Ok = 0, NoChange = 1, Pending = 2,
    InvalidArgument = 10, AbiMismatch, Unsupported, InvalidHandle, WrongHandleType,
    ResourceLimit, OutOfMemory, Stale, NotConnected, Closing, Busy, QueueFull,
    Cancelled, NotPending, Failed, InternalFailure, ViewOnly, Unfocused, Disabled, Echo,
}

/// <summary>A failed C ABI call: status, domain, detail and the fixed diagnostic text.</summary>
public sealed class NativeError : Exception
{
    public NativeStatus Status { get; }
    public uint Domain { get; }
    public uint Detail { get; }
    /// <summary>Platform code (Winsock/Win32 on Windows); classify with <see cref="NativeErrorCategories"/>.</summary>
    public int NativeCode { get; }

    public NativeError(NativeStatus status, string message) : base(message)
    {
        Status = status; Domain = Tidyvnc.TIDYVNC_DOMAIN_BRIDGE;
    }

    internal unsafe NativeError(tidyvnc_error value) : base(NativeText.Fixed(value.message, 160))
    {
        Status = Enum.IsDefined((NativeStatus)value.code) ? (NativeStatus)value.code : NativeStatus.InternalFailure;
        Domain = value.domain; Detail = value.detail; NativeCode = value.native_error;
    }

    public override string ToString() => $"{Status} ({Domain}/{Detail}): {Message}";
}

/// <summary>Helpers shared by every wrapper: ABI headers, checked calls and text.</summary>
internal static unsafe class Abi
{
    /// <summary>A zeroed struct whose leading size/version fields are initialized.</summary>
    public static T Init<T>() where T : unmanaged
    {
        T value = default;
        var header = (uint*)&value;
        header[0] = (uint)sizeof(T);
        header[1] = Tidyvnc.TIDYVNC_ABI_VERSION;
        return value;
    }

    /// <summary>
    /// Throws unless the returned status is allowed. Usage:
    /// <c>var e = Abi.Init&lt;tidyvnc_error&gt;(); Abi.Check(NativeMethods.f(..., &amp;e), &amp;e);</c>
    /// </summary>
    public static NativeStatus Check(uint code, tidyvnc_error* error, NativeStatus allowed1 = NativeStatus.Ok,
                                     NativeStatus allowed2 = NativeStatus.Ok, NativeStatus allowed3 = NativeStatus.Ok)
    {
        var status = (NativeStatus)code;
        if (status == allowed1 || status == allowed2 || status == allowed3)
            return status;
        throw new NativeError(*error);
    }
}

/// <summary>UTF-8 conversions at the ABI boundary.</summary>
internal static unsafe class NativeText
{
    /// <summary>A NUL-terminated fixed char array, decoded as UTF-8 (invalid bytes replaced).</summary>
    public static string Fixed(byte* bytes, int capacity)
    {
        var length = 0;
        while (length < capacity && bytes[length] != 0) length++;
        return Encoding.UTF8.GetString(bytes, length);
    }

    /// <summary>Copies a borrowed span into managed memory.</summary>
    public static byte[] Copy(tidyvnc_bytes bytes)
    {
        if (bytes.length == 0) return [];
        if (bytes.data == null || bytes.length > int.MaxValue) throw new NativeError(NativeStatus.InternalFailure, "Invalid owned payload span");
        return new ReadOnlySpan<byte>(bytes.data, (int)bytes.length).ToArray();
    }

    public static string Decode(tidyvnc_bytes bytes) => Encoding.UTF8.GetString(Copy(bytes));

    /// <summary>
    /// UTF-8 bytes pinned for one call: <c>fixed (byte* p = bytes)</c> then
    /// <see cref="Span(byte*, int)"/>. Arrays from here are safe to pin.
    /// </summary>
    public static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    public static tidyvnc_bytes Span(byte* data, int length) => new() { data = data, length = (ulong)length };

    /// <summary>Zeroes managed secret storage (the ABI wipes its own copies).</summary>
    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
    public static void Wipe(Span<byte> bytes) => bytes.Clear();
}
