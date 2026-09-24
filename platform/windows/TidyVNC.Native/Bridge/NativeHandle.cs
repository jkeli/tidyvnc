// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// One owned reference to a tidyvnc handle (PLAN.md section 5, "Handles").
/// Release is nonblocking in the C ABI: a final session or runtime release only
/// initiates close, so finalization never joins a worker. Explicit, awaited
/// close and drain belong to the owning wrapper (<see cref="NativeSession"/>).
/// </summary>
internal sealed class NativeHandle : SafeHandle
{
    // Constructed only through Adopt/Retain; public for SafeHandle marshalling rules.
    public NativeHandle() : base(IntPtr.Zero, true) { }

    /// <summary>Takes ownership of a reference returned by the ABI.</summary>
    public static NativeHandle Adopt(ulong raw)
    {
        if (raw == 0) throw new NativeError(NativeStatus.InvalidHandle, "Missing native handle");
        var handle = new NativeHandle();
        handle.SetHandle(new IntPtr(unchecked((long)raw)));
        return handle;
    }

    /// <summary>Adds a reference to a borrowed handle (for example a callback's subscription).</summary>
    public static unsafe NativeHandle Retain(ulong raw)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_retain(raw, &error), &error);
        return Adopt(raw);
    }

    /// <summary>The raw handle ID. Keep this object alive for the duration of any call using it.</summary>
    public ulong Raw => (ulong)(long)handle;

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override unsafe bool ReleaseHandle() => NativeMethods.tidyvnc_release(Raw, null) == Tidyvnc.TIDYVNC_OK;
}
