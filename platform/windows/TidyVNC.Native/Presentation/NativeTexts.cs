// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Clipboard;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native;

/// <summary>
/// Catalog references for typed states and failures shown in the connection
/// window (the macOS endpointMessage, preferencesMessage, profileMessage,
/// historyMessage, credential notices and connection status texts).
/// </summary>
public static class NativeTexts
{
    public static NativeText? Endpoint(NativeEndpointIssue? issue) => issue switch
    {
        null or NativeEndpointIssue.Required => null,
        NativeEndpointIssue.TooLong => new("endpoint.issue.the.server.address.is.too.long.maximum.4096.utf.8.bytes"),
        NativeEndpointIssue.InvalidHost => new("endpoint.issue.check.the.host.name.or.ip.address.put.ipv6.addresses.in.brackets"),
        NativeEndpointIssue.UnmatchedBracket => new("endpoint.issue.add.the.closing.bracket.after.the.ipv6.address.or.host.name"),
        NativeEndpointIssue.InvalidPort => new("endpoint.issue.use.host.display.or.host.port.the.port.must.be.between.1"),
        NativeEndpointIssue.InvalidPath => new("endpoint.issue.the.unix.socket.path.contains.invalid.text"),
        NativeEndpointIssue.InvalidRoute => new("endpoint.issue.the.connection.route.is.invalid"),
        NativeEndpointIssue.UnsupportedTransport => new("endpoint.issue.unix.socket.connections.are.unavailable.for.this.connection"),
        NativeEndpointIssue.InvalidText => new("endpoint.issue.the.server.address.contains.invalid.text.check.the.address.and.try.again"),
        _ => new("endpoint.issue.the.server.address.could.not.be.checked.try.again"),
    };

    /// <summary>App defaults (preferences.json) failures.</summary>
    public static NativeText Preferences(NativeStorageError error) => new(error switch
    {
        NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields => "settings.defaults.these.saved.defaults.require.a.newer.version.of.tidyvnc.they.have.been",
        NativeStorageError.Invalid => "settings.defaults.a.setting.is.outside.the.supported.range.saved.values.have.been.preserved",
        NativeStorageError.Corrupt or NativeStorageError.TooLarge => "settings.defaults.saved.defaults.could.not.be.read.they.have.been.preserved",
        NativeStorageError.Conflict => "settings.defaults.saved.defaults.changed.while.you.were.editing.reload.them.before.applying.changes",
        NativeStorageError.Denied => "settings.defaults.access.to.saved.defaults.was.denied.check.access.and.try.again",
        NativeStorageError.Cancelled => "settings.defaults.the.defaults.operation.was.cancelled.reload.to.check.the.saved.values",
        NativeStorageError.IOFailure => "settings.defaults.the.defaults.operation.could.not.be.confirmed.reload.to.check.the.saved",
        _ => "settings.defaults.saved.defaults.are.unavailable.try.again",
    });

    /// <summary>Saved profile failures.</summary>
    public static NativeText Profile(NativeStorageError error) => new(error switch
    {
        NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields => "profiles.saved.profiles.require.a.newer.version.of.tidyvnc.existing.data.has.been",
        NativeStorageError.Denied => "profiles.access.to.saved.profiles.was.denied.check.the.native.storage.folder.s",
        NativeStorageError.Conflict => "profiles.saved.profiles.or.recent.connections.changed.elsewhere.reload.before.saving.or.deleting",
        NativeStorageError.NotFound => "profiles.this.saved.profile.is.no.longer.available.choose.another.profile.or.create",
        NativeStorageError.Invalid or NativeStorageError.TooLarge or NativeStorageError.ResourceLimit => "profiles.the.profile.could.not.be.saved.check.the.name.address.and.settings",
        NativeStorageError.Corrupt => "profiles.saved.profiles.could.not.be.read.existing.data.has.been.preserved",
        NativeStorageError.Cancelled or NativeStorageError.IOFailure => "profiles.the.profile.operation.could.not.be.confirmed.reload.to.check.the.saved",
        _ => "profiles.saved.profiles.are.unavailable.try.reloading",
    });

    /// <summary>Recent connections failures.</summary>
    public static NativeText History(NativeStorageError error) => new(error switch
    {
        NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields => "history.recent.connections.require.a.newer.version.of.tidyvnc.saved.data.has.been",
        NativeStorageError.Corrupt or NativeStorageError.Invalid or NativeStorageError.TooLarge or NativeStorageError.ResourceLimit =>
            "history.recent.connections.could.not.be.read.or.saved.existing.data.has.been",
        NativeStorageError.Denied => "history.access.to.recent.connections.was.denied.check.the.native.storage.folder.s",
        NativeStorageError.Conflict => "history.saved.connections.changed.elsewhere.reload.before.making.changes",
        NativeStorageError.NotFound => "history.the.saved.connection.or.its.storage.folder.is.no.longer.available.try",
        NativeStorageError.Cancelled or NativeStorageError.IOFailure => "history.the.history.update.could.not.be.confirmed.reload.to.check.the.saved",
        _ => "history.recent.connections.are.unavailable.try.again",
    });

    public static NativeText PasswordFile(NativePasswordFileError error) => new(error switch
    {
        NativePasswordFileError.NotRegular => "credentials.file.the.password.file.must.be.a.regular.file",
        NativePasswordFileError.Truncated => "credentials.file.the.password.file.does.not.contain.a.complete.legacy.password.block",
        NativePasswordFileError.Changed => "credentials.file.the.password.file.changed.while.being.read.retry.with.its.current.contents",
        NativePasswordFileError.Cancelled => "credentials.file.reading.the.password.file.was.cancelled",
        _ => "credentials.file.the.password.file.could.not.be.read.check.its.location.and.access",
    });

    /// <summary>Credential Manager failures (Windows has no interaction or signing-identity cases).</summary>
    public static NativeText CredentialStore(NativeCredentialError? error) => new(error switch
    {
        NativeCredentialError.NotFound => "credentials.no.saved.password.matches.this.server.authentication.method.and.username",
        NativeCredentialError.Unavailable => "credentials.the.keychain.is.unavailable.enter.a.password.to.continue",
        NativeCredentialError.Denied => "credentials.keychain.access.was.denied",
        NativeCredentialError.Cancelled => "credentials.keychain.access.was.cancelled",
        NativeCredentialError.Duplicate => "credentials.a.saved.password.already.exists.choose.explicit.replacement.on.a.subsequent.authentication",
        NativeCredentialError.Corrupt => "credentials.the.saved.credential.could.not.be.read.it.has.not.been.changed",
        _ => "credentials.the.keychain.operation.failed.no.plaintext.copy.was.saved",
    });

    public static NativeText Credential(NativeCredentialNotice notice) => notice.Kind switch
    {
        NativeCredentialNoticeKind.LaunchFailure => new("credentials.launch.failure",
            notice.FileError is { } file ? PasswordFile(file) : new NativeText("credentials.launch.unavailable")),
        NativeCredentialNoticeKind.Saved => new("credentials.password.saved.on.this.mac"),
        NativeCredentialNoticeKind.SaveUnconfirmed => new("credentials.save.unconfirmed", CredentialStore(notice.StoreError)),
        NativeCredentialNoticeKind.SavedPasswordRejected => new("credentials.the.server.rejected.the.saved.password.retry.to.enter.a.replacement.or"),
        NativeCredentialNoticeKind.Removed => new("credentials.the.saved.password.was.removed.from.this.mac"),
        NativeCredentialNoticeKind.RequestUnavailable => new("credentials.this.authentication.request.is.no.longer.available"),
        _ => CredentialStore(notice.StoreError),
    };

    public static NativeText Clipboard(NativeClipboardNotice notice) => new(notice switch
    {
        NativeClipboardNotice.LocalNotSent => "clipboard.recovery.the.local.clipboard.could.not.be.sent.copy.plain.text.of.at",
        NativeClipboardNotice.TransferFailed => "clipboard.recovery.clipboard.transfer.failed.copy.the.text.again.to.retry",
        NativeClipboardNotice.RemoteRejected => "clipboard.recovery.the.remote.clipboard.text.could.not.be.accepted",
        _ => "clipboard.recovery.the.remote.clipboard.could.not.be.written.on.this.mac.copy.it",
    });

    /// <summary>The status bar text for a connection state (the empty-state title when idle is separate).</summary>
    public static NativeText Status(NativeSessionState state) => new(state switch
    {
        NativeSessionState.Idle => "app.ready",
        NativeSessionState.Resolving => "app.resolving.server",
        NativeSessionState.Connecting or NativeSessionState.Negotiating => "app.connecting",
        NativeSessionState.Authenticating => "app.waiting.for.authentication",
        NativeSessionState.Connected => "app.connected",
        NativeSessionState.Disconnecting => "app.disconnecting",
        NativeSessionState.Closed => "app.disconnected",
        _ => "app.connection.failed",
    });
}
