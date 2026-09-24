// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native.Desktop;

/// <summary>The desktop view a command acts on (the window's own, or the focused full-screen surface).</summary>
public interface INativeDesktopCommandHost
{
    /// <summary>Gives the desktop keyboard focus so the session accepts keys; false when it cannot.</summary>
    bool FocusForCommand();
    /// <summary>Forgets locally held key state after input was released for a command.</summary>
    void ClearCommandInput();
}

/// <summary>
/// The Connection menu's key commands (macOS NativeDesktopCommands; PARITY
/// M05-M07): Hold Ctrl and Hold Alt keep a modifier pressed on the remote
/// computer until chosen again, surviving focus changes by pressing it again
/// when the desktop regains focus; Send Ctrl+Alt+Del is the only way to send
/// that chord. Each starts from a clean input state; the synthetic keys use
/// IDs outside the physical key range. UI thread only.
/// </summary>
public sealed partial class NativeDesktopCommands : ObservableObject
{
    private const uint ControlSym = 0xffe3, AltSym = 0xffe9, DeleteSym = 0xffff;
    private const uint ControlCode = 0x1d, AltCode = 0x38, DeleteCode = 0xd3;
    private const uint SyntheticBase = 0x200000;

    private NativeSession? session;
    private INativeDesktopCommandHost? host;
    private bool sentControl, sentAlt, recoveryQueued, stopped;

    [ObservableProperty] public partial bool ControlSelected { get; private set; }
    [ObservableProperty] public partial bool AltSelected { get; private set; }

    public void Bind(NativeSession value)
    {
        if (stopped || ReferenceEquals(session, value)) return;
        if (session is not null) session.PropertyChanged -= SessionChanged;
        session = value;
        ControlSelected = false; AltSelected = false; sentControl = false; sentAlt = false;
        value.PropertyChanged += SessionChanged;
        OnPropertyChanged(nameof(CanSendKeys));
    }

    /// <summary>The desktop view that now owns keyboard focus for commands.</summary>
    public void Attach(INativeDesktopCommandHost value)
    {
        if (stopped || ReferenceEquals(host, value)) return;
        host = value;
        sentControl = false; sentAlt = false;
        ScheduleRecovery();
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(NativeSession.Snapshot) when session?.Snapshot.State != NativeSessionState.Connected:
                ControlSelected = false; AltSelected = false; sentControl = false; sentAlt = false;
                break;
            case nameof(NativeSession.IsFocused) when session?.IsFocused == false:
            case nameof(NativeSession.IsViewOnly):
                // Focus loss and view-only release everything remotely; press again when allowed.
                sentControl = false; sentAlt = false;
                ScheduleRecovery();
                break;
            case nameof(NativeSession.IsFocused):
                ScheduleRecovery();
                break;
        }
        OnPropertyChanged(nameof(CanSendKeys));
    }

    private bool Connected => !stopped && session is { IsClosing: false, Snapshot.State: NativeSessionState.Connected };

    /// <summary>Hold Ctrl, Hold Alt and Send Ctrl+Alt+Del need a connected, controllable desktop.</summary>
    public bool CanSendKeys => Connected && session!.IsViewOnly == false && host is not null;

    public void ToggleControl() => Chord(() => ControlSelected = !ControlSelected, chord: false);
    public void ToggleAlt() => Chord(() => AltSelected = !AltSelected, chord: false);
    public void SendControlAltDelete() => Chord(() => { }, chord: true);

    private void Chord(Action select, bool chord)
    {
        if (!CanSendKeys || session is not { } s || host is not { } target || !target.FocusForCommand() || !s.IsFocused)
            throw new NativeError(NativeStatus.NotConnected, "The desktop cannot take keys now");
        bool previousControl = ControlSelected, previousAlt = AltSelected;
        try
        {
            // Every command starts from a clean remote and local input state.
            s.ReleaseInput();
            target.ClearCommandInput();
            sentControl = false; sentAlt = false;
            select();
            if (chord)
            {
                Key(ControlSym, ControlCode, true); Key(AltSym, AltCode, true);
                Key(DeleteSym, DeleteCode, true); Key(DeleteSym, DeleteCode, false);
                if (!AltSelected) Key(AltSym, AltCode, false);
                if (!ControlSelected) Key(ControlSym, ControlCode, false);
                sentControl = ControlSelected; sentAlt = AltSelected;
            }
            else RestoreModifiers();
        }
        catch
        {
            ControlSelected = previousControl; AltSelected = previousAlt;
            try { s.SetFocused(false); } catch (NativeError) { }
            target.ClearCommandInput();
            sentControl = false; sentAlt = false;
            throw;
        }
    }

    private void Key(uint symbol, uint code, bool down) => session!.SendKey(SyntheticBase + symbol, symbol, code, down);

    private void RestoreModifiers()
    {
        if (!Connected || session is not { IsFocused: true, IsViewOnly: false } || host is null) return;
        if (sentControl != ControlSelected) { Key(ControlSym, ControlCode, ControlSelected); sentControl = ControlSelected; }
        if (sentAlt != AltSelected) { Key(AltSym, AltCode, AltSelected); sentAlt = AltSelected; }
    }

    /// <summary>The user released a physical Ctrl or Alt: a held menu modifier is pressed again.</summary>
    public void PhysicalModifierReleased(uint keysym)
    {
        if (keysym is 0xffe3 or 0xffe4) sentControl = false;
        if (keysym is 0xffe9 or 0xffea) sentAlt = false;
        try { RestoreModifiers(); }
        catch (NativeError) { try { session?.SetFocused(false); } catch (NativeError) { } }
    }

    /// <summary>Input was released for a viewer shortcut; the held modifiers are pressed again afterwards.</summary>
    public void InputReleased()
    {
        sentControl = false; sentAlt = false;
        ScheduleRecovery();
    }

    private void ScheduleRecovery()
    {
        if (recoveryQueued || stopped) return;
        recoveryQueued = true;
        _ = Recover();
    }

    private async Task Recover()
    {
        // Property callbacks run mid-update; press again only once the whole change is visible.
        await Task.Yield();
        recoveryQueued = false;
        if (stopped) return;
        try { RestoreModifiers(); }
        catch (NativeError)
        {
            try { session?.SetFocused(false); } catch (NativeError) { }
            host?.ClearCommandInput();
        }
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        if (session is not null)
        {
            session.PropertyChanged -= SessionChanged;
            if ((sentControl || sentAlt) && !session.IsClosing) { try { session.SetFocused(false); } catch (NativeError) { } }
        }
        host?.ClearCommandInput();
        ControlSelected = false; AltSelected = false; sentControl = false; sentAlt = false;
        session = null; host = null;
    }
}
