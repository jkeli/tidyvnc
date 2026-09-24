// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// Viewer shortcut modifiers. The bits are the core's; on Windows "Control"
/// is Ctrl, "Option" is Alt and "Command" is the Windows key (UX.md section 7).
/// </summary>
[Flags]
public enum NativeShortcutModifiers : uint
{
    None = 0, Control = 1, Shift = 2, Option = 4, Command = 8,
    BuiltIn = Control | Option,
}

public enum NativeShortcutAction : uint { Normal, Unarm, Shortcut, Ignore }

/// <summary>One core shortcut classifier per input surface (NativeShortcutState).</summary>
public sealed class NativeShortcutState : IDisposable
{
    private readonly NativeHandle handle;

    public unsafe NativeShortcutState(NativeShortcutModifiers modifiers = NativeShortcutModifiers.BuiltIn)
    {
        ulong raw = 0;
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_shortcut_create((uint)modifiers, &raw, &error), &error);
        handle = NativeHandle.Adopt(raw);
    }

    public unsafe void SetModifiers(NativeShortcutModifiers value)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_shortcut_modifiers(handle.Raw, (uint)value, &error), &error);
    }

    public unsafe void Reset()
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_shortcut_reset(handle.Raw, &error), &error);
    }

    public unsafe NativeShortcutAction Key(int id, uint keysym, bool down)
    {
        uint action = 0;
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_shortcut_key(handle.Raw, id, keysym, down ? 1u : 0u, &action, &error), &error);
        if (!Enum.IsDefined((NativeShortcutAction)action)) throw new NativeError(NativeStatus.InternalFailure, "Invalid shortcut action");
        return (NativeShortcutAction)action;
    }

    public void Dispose() => handle.Dispose();
}

public readonly record struct NativeShortcutDecision(NativeShortcutDecision.RouteKind Route, bool ReleaseRemoteKeys = false)
{
    public enum RouteKind { Remote, Suppress, ReleaseKeyboard, CaptureKeyboard, ContextMenu, ToggleFullscreen }
}

/// <summary>The retained viewer's Space bypass and command selection (NativeShortcutRouter).</summary>
public sealed class NativeShortcutRouter : IDisposable
{
    private readonly NativeShortcutState state;
    private readonly HashSet<int> pressed = [];
    private bool bypass, active;

    public NativeShortcutRouter(NativeShortcutModifiers modifiers = NativeShortcutModifiers.BuiltIn) => state = new NativeShortcutState(modifiers);

    public void SetModifiers(NativeShortcutModifiers modifiers)
    {
        state.SetModifiers(modifiers); pressed.Clear(); bypass = false; active = false;
    }

    public void Reset()
    {
        state.Reset(); pressed.Clear(); bypass = false; active = false;
    }

    /// <summary>True while a chord or bypass owns keys (accelerators must then stay remote).</summary>
    public bool RoutesKeyEquivalents => active || bypass;

    /// <summary>Candidates are ordered layout translations of the physical key, including unmodified variants.</summary>
    public NativeShortcutDecision Press(int id, uint keysym, Func<IReadOnlyList<uint>> candidates)
    {
        if (!pressed.Contains(id) && pressed.Count >= 1024) throw new NativeError(NativeStatus.ResourceLimit, "Shortcut key capacity exceeded");
        var action = bypass ? NativeShortcutAction.Normal : state.Key(id, keysym, true);
        pressed.Add(id);
        switch (action)
        {
            case NativeShortcutAction.Ignore: return new(NativeShortcutDecision.RouteKind.Suppress);
            case NativeShortcutAction.Shortcut:
                uint[] commands = [0x20, 0x47, 0x67, 0x4d, 0x6d, 0xff0d, 0xff8d];
                var symbol = candidates().FirstOrDefault(commands.Contains);
                if (symbol == 0x20)
                {
                    if (!active) { state.Reset(); bypass = true; }
                    return new(NativeShortcutDecision.RouteKind.Suppress);
                }
                active = true;
                return symbol switch
                {
                    0x47 or 0x67 => new(NativeShortcutDecision.RouteKind.CaptureKeyboard, true),
                    0x4d or 0x6d => new(NativeShortcutDecision.RouteKind.ContextMenu, true),
                    0xff0d or 0xff8d => new(NativeShortcutDecision.RouteKind.ToggleFullscreen, true),
                    _ => new(NativeShortcutDecision.RouteKind.Suppress, true),
                };
            default: return new(NativeShortcutDecision.RouteKind.Remote);
        }
    }

    public NativeShortcutDecision Release(int id)
    {
        var action = bypass ? NativeShortcutAction.Normal : state.Key(id, 0, false);
        pressed.Remove(id);
        if (pressed.Count == 0) active = false;
        switch (action)
        {
            case NativeShortcutAction.Ignore or NativeShortcutAction.Shortcut: return new(NativeShortcutDecision.RouteKind.Suppress);
            case NativeShortcutAction.Unarm: return new(NativeShortcutDecision.RouteKind.ReleaseKeyboard, true);
            default:
                if (pressed.Count == 0) bypass = false;
                return new(NativeShortcutDecision.RouteKind.Remote);
        }
    }

    public void Dispose() => state.Dispose();
}
