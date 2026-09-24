// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using Microsoft.UI.Input;

namespace TidyVNC;

/// <summary>
/// A WinUI <see cref="InputCursor"/> for a Win32 HCURSOR (D13): the Windows App
/// SDK's IInputCursorStaticsInterop.CreateFromHCursor
/// (Microsoft.UI.Input.InputCursor.Interop.h). The HCURSOR must outlive the
/// returned cursor's use.
/// </summary>
internal static unsafe class InputCursors
{
    private static readonly Guid StaticsInterop = new("ac6f5065-90c4-46ce-beb7-05e138e54117");

    public static InputCursor FromHandle(IntPtr hcursor)
    {
        var factory = WinRT.ActivationFactory.Get("Microsoft.UI.Input.InputCursor");
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in StaticsInterop, out var statics));
        try
        {
            IntPtr result;
            // IInspectable's six methods come first; CreateFromHCursor is the seventh slot.
            var create = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr*, int>)(*(void***)statics)[6];
            Marshal.ThrowExceptionForHR(create(statics, hcursor, &result));
            try { return InputCursor.FromAbi(result); }
            finally { Marshal.Release(result); }
        }
        finally
        {
            Marshal.Release(statics);
        }
    }
}
