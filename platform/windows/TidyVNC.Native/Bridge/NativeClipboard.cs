// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>An advisory clipboard routing token (NativeClipboardRoute).</summary>
public readonly record struct NativeClipboardRoute(ulong SessionIdentity, ulong Generation, ulong FocusRevision, ulong PolicyRevision)
{
    internal static NativeClipboardRoute From(tidyvnc_clipboard_route value)
        => new(value.session, value.generation, value.focus_revision, value.policy_revision);

    internal tidyvnc_clipboard_route ToAbi()
    {
        var value = Abi.Init<tidyvnc_clipboard_route>();
        value.session = SessionIdentity; value.generation = Generation;
        value.focus_revision = FocusRevision; value.policy_revision = PolicyRevision;
        return value;
    }
}

/// <summary>
/// Clipboard text plus its retained core lease, which keeps the shared byte
/// budget and remote provenance (echo suppression) accounted.
/// </summary>
public sealed class NativeClipboardText : IDisposable
{
    internal NativeHandle Handle { get; }
    public string Text { get; }
    public bool FromRemote { get; }
    public NativeClipboardRoute Route { get; }

    internal unsafe NativeClipboardText(NativeHandle owner)
    {
        var value = Abi.Init<tidyvnc_clipboard_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_clipboard_get(owner.Raw, &value, &error), &error);
        try { Text = new System.Text.UTF8Encoding(false, true).GetString(NativeText.Copy(value.text)); }
        catch (System.Text.DecoderFallbackException) { owner.Dispose(); throw new NativeError(NativeStatus.InvalidArgument, "Invalid clipboard text encoding"); }
        FromRemote = value.from_remote != 0; Route = NativeClipboardRoute.From(value.route); Handle = owner;
    }

    public void Dispose() => Handle.Dispose();
}

public sealed record NativeClipboardUpdate(NativeClipboardUpdate.UpdateKind Kind, NativeStatus Result, ulong Sequence,
                                           NativeClipboardRoute Route, NativeClipboardText? Text)
{
    public enum UpdateKind : uint { Offered = 1, Text, Unavailable, Invalidated, Rejected }

    internal static NativeClipboardUpdate From(tidyvnc_clipboard_update value)
    {
        // Adopt before interpreting metadata so a conversion failure cannot leak.
        var text = value.text == 0 ? null : new NativeClipboardText(NativeHandle.Adopt(value.text));
        return new NativeClipboardUpdate(
            Enum.IsDefined((UpdateKind)value.kind) ? (UpdateKind)value.kind : UpdateKind.Rejected,
            Enum.IsDefined((NativeStatus)value.result) ? (NativeStatus)value.result : NativeStatus.InternalFailure,
            value.sequence, NativeClipboardRoute.From(value.route), text);
    }
}
