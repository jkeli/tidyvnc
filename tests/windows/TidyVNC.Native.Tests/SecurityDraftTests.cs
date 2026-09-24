// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Trust;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Security for a window's next connection (plans/native-ui-winui TODO W5.5):
/// inheritance from the window's initial settings, the off-thread GnuTLS
/// preflight, revision-checked apply, the effect on the next attempt, and
/// invalidation when an attempt starts.
/// </summary>
[TestClass]
public sealed class SecurityDraftTests
{
    private static async Task Until(Func<bool> condition, string label)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(2);
        }
    }

    [TestMethod]
    public async Task EditsInheritApplyForTheNextAttemptAndInvalidateOnConnect()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await using var second = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1, 2], SecuritySource = NativeOptionSource.AppDefaults });
            var applied = 0;
            using var draft = new NativeSessionSecurityDraft(session, () => applied++);
            Assert.AreEqual("None,VncAuth", draft.Inherited.Canonical, "inherits the window's initial methods");
            draft.Reload();
            Assert.IsNotNull(draft.Baseline);
            Assert.IsFalse(draft.HasChanges);
            Assert.IsNull(draft.Preferences.Types, "the initial selection is shown as inherited");
            Assert.AreEqual((NativeOptionSource.AppDefaults, NativeOptionSource.Compiled), draft.Sources);

            // An invalid priority is caught by the preflight, never applied.
            draft.Preferences = draft.Preferences with { TlsPriority = "NOT-A-PRIORITY:%%" };
            Assert.IsTrue(draft.CanApply);
            draft.Apply();
            await Until(() => !draft.IsBusy, "preflight");
            Assert.AreEqual(NativeSecurityDraftError.InvalidPriority, draft.Error);
            Assert.AreEqual(0, applied);
            Assert.AreEqual("", session.SecurityConfiguration().TlsPriority, "nothing reached the session");
            draft.CancelEdits();
            Assert.IsFalse(draft.HasChanges);

            // An unavailable selection disables Apply; an empty one is allowed and warned about by the fields.
            draft.Preferences = draft.Preferences with { Types = "NotAMethod" };
            Assert.IsFalse(draft.CanApply);
            draft.Preferences = draft.Preferences with { Types = "VncAuth" };
            draft.TrustFiles = new NativeTrustFiles(@"relative\ca.pem", null);
            Assert.IsFalse(draft.CanApply, "certificate files need full paths");
            draft.TrustFiles = new NativeTrustFiles(null, null);
            draft.Apply();
            await Until(() => !draft.IsBusy, "apply");
            Assert.IsTrue(draft.DidApply && draft.Error is null);
            Assert.AreEqual(1, applied, "the window forgets session passwords and trust work for the old settings");
            Assert.AreEqual("VncAuth", session.SecurityConfiguration().Types);
            Assert.AreEqual((NativeOptionSource.Session, NativeOptionSource.Session), draft.Sources, "a connection override");

            // The next attempt uses it: the unauthenticated peer offers only None, now refused.
            try { await session.ConnectAsync(peer.Endpoint); Assert.Fail("None should be refused"); }
            catch (NativeCommandFailure) { }
            Assert.AreEqual(NativeSessionState.Failed, session.Snapshot.State);

            // Starting an attempt invalidates the dialog's baseline.
            draft.Preferences = draft.Preferences with { Types = "None,VncAuth" };
            var attempt = session.ConnectAsync(second.Endpoint);
            await Until(() => draft.NeedsReload, "invalidated");
            Assert.AreEqual(NativeSecurityDraftError.ConnectionChanged, draft.Error);
            Assert.IsFalse(draft.CanApply);
            try { await attempt; } catch (NativeCommandFailure) { }
            await session.CloseAsync();
            Assert.IsFalse(draft.CanReload, "a closing session cannot be edited");
            await draft.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }
}
