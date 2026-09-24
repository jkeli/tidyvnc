// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native;

/// <summary>
/// A presentation failure (NativePresentationIssue.swift), selected only by
/// typed failures and the operation being shown. Error descriptions, paths,
/// endpoints and remote payloads are never kept.
/// </summary>
public enum NativePresentationIssue
{
    StartupUnavailable, StartupIncompatible, StartupResources, PreferencesUnavailable, DesktopUnavailable, DesktopResources,
    CursorUnavailable, LayoutUnavailable, LayoutResources, DisplaysUnavailable, InputUnavailable, InputBusy, InputFailed,
    ShortcutUnavailable, KeyboardCaptureUnavailable, KeyboardCaptureFailed, FullscreenUnavailable, CommandUnavailable,
}

public enum NativePresentationContext { Startup, Desktop, Cursor, Layout, Input, Shortcut, Fullscreen, Command }

public static class NativePresentationIssues
{
    public static NativePresentationIssue From(Exception error, NativePresentationContext context)
    {
        var status = (error as NativeError)?.Status;
        var limited = status is NativeStatus.ResourceLimit or NativeStatus.OutOfMemory;
        if (context == NativePresentationContext.Startup)
        {
            if (error is NativeStorageException) return NativePresentationIssue.PreferencesUnavailable;
            if (status is NativeStatus.AbiMismatch or NativeStatus.Unsupported) return NativePresentationIssue.StartupIncompatible;
            return limited ? NativePresentationIssue.StartupResources : NativePresentationIssue.StartupUnavailable;
        }
        if (error is NativeKeyboardCaptureException capture)
            return capture.Failure == NativeKeyboardCaptureFailure.Unavailable
                ? NativePresentationIssue.KeyboardCaptureUnavailable : NativePresentationIssue.KeyboardCaptureFailed;
        if (error is NativeDisplayException display)
            return display.Error == NativeDisplayError.TooManyDisplays ? NativePresentationIssue.LayoutResources : NativePresentationIssue.DisplaysUnavailable;
        return context switch
        {
            NativePresentationContext.Desktop => limited ? NativePresentationIssue.DesktopResources : NativePresentationIssue.DesktopUnavailable,
            NativePresentationContext.Cursor => NativePresentationIssue.CursorUnavailable,
            NativePresentationContext.Layout => limited ? NativePresentationIssue.LayoutResources : NativePresentationIssue.LayoutUnavailable,
            NativePresentationContext.Fullscreen => limited ? NativePresentationIssue.LayoutResources : NativePresentationIssue.FullscreenUnavailable,
            _ => status switch
            {
                NativeStatus.NotConnected or NativeStatus.ViewOnly or NativeStatus.Unfocused or NativeStatus.Disabled => NativePresentationIssue.InputUnavailable,
                NativeStatus.Busy or NativeStatus.QueueFull => NativePresentationIssue.InputBusy,
                _ => context switch
                {
                    NativePresentationContext.Shortcut => NativePresentationIssue.ShortcutUnavailable,
                    NativePresentationContext.Command => NativePresentationIssue.CommandUnavailable,
                    _ => NativePresentationIssue.InputFailed,
                },
            },
        };
    }

    public static NativeText Message(this NativePresentationIssue issue) => new(issue switch
    {
        NativePresentationIssue.KeyboardCaptureUnavailable => "desktop.keyboard.capture.is.unavailable.allow.tidyvnc.in.macos.accessibility.settings.and.try",
        NativePresentationIssue.FullscreenUnavailable => "desktop.fullscreen.full.screen.could.not.be.opened.review.fullscreen.displays.or.use.enter",
        NativePresentationIssue.CommandUnavailable => "connection.recovery.this.desktop.command.is.unavailable.focus.the.connected.desktop.and.try.again",
        _ => "presentation.issue." + char.ToLowerInvariant(issue.ToString()[0]) + issue.ToString()[1..],
    });
}
