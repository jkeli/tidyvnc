// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The per-connection encoding editor (plans/native-ui-winui TODO W5.4),
/// ported from the macOS NativeEncodingDraftTests: canonical edits,
/// competing edits, uncertain completion, generation guards, a real
/// session pair and the controller's single-editor rule.
/// </summary>
[TestClass]
public sealed class EncodingDraftTests
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

    private sealed class Target : INativeEncodingTarget
    {
        public enum Behavior { Succeed, FailBefore, FailAfter, SuspendBefore, SuspendAfter }

        private TaskCompletionSource release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public NativeEncodingOptions Options { get; set; } = new NativeEncodingOptions([new("QualityLevel", "3"), new("AutoSelect", "off")], NativeOptionSource.AppDefaults);
        public ulong EncodingGeneration { get; set; } = 1;
        public bool EncodingEditable { get; set; } = true;
        public Behavior Mode { get; set; }
        public int Calls { get; private set; }
        public bool IsSuspended { get; private set; }

        public NativeEncodingOptions ReadEncoding() => Options;

        public void Release() => release.TrySetResult();

        public async Task SubmitEncodingAsync(NativeEncodingOptions options, ulong generation, CancellationToken cancellation)
        {
            Calls++;
            switch (Mode)
            {
                case Behavior.FailBefore: throw new NativeError(NativeStatus.Failed, "fixture");
                case Behavior.FailAfter: Options = options; throw new NativeError(NativeStatus.Failed, "fixture");
                case Behavior.SuspendBefore:
                    IsSuspended = true;
                    await release.Task.WaitAsync(cancellation);
                    break;
                case Behavior.SuspendAfter:
                    // Accepted work: cancelling cannot undo it; the caller learns of the cancel after it finishes.
                    Options = options;
                    IsSuspended = true;
                    await release.Task;
                    IsSuspended = false;
                    cancellation.ThrowIfCancellationRequested();
                    break;
            }
            Options = options;
            IsSuspended = false;
            release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }
    }

    [TestMethod]
    public async Task EditsAreCanonicalAndCompetingEditsNeedReload()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var target = new Target();
            using var draft = new NativeSessionEncodingDraft(target);
            draft.Reload();
            draft.SetEncoding(NativeEncodingOption.Quality, "0x5");
            Assert.AreEqual(new NativeEncodingValue("5", NativeOptionSource.Session), draft.Values[NativeEncodingOption.Quality]);
            Assert.IsTrue(draft.CanApply);
            Assert.AreEqual(("3", 0), (target.Options.Value(NativeEncodingOption.Quality).Value, target.Calls), "editing never submits");
            draft.CancelEdits();
            Assert.IsFalse(draft.HasChanges);
            Assert.AreEqual(NativeOptionSource.AppDefaults, draft.Values[NativeEncodingOption.Quality].Source);
            draft.SetEncoding(NativeEncodingOption.Quality, "100");
            Assert.AreEqual(NativeEncodingDraftError.InvalidValue, draft.Error);
            Assert.IsFalse(draft.NeedsReload || draft.HasChanges, "invalid input keeps the draft");
            draft.SetEncoding(NativeEncodingOption.Quality, "5");
            draft.Apply();
            await Until(() => !draft.IsBusy, "first apply");
            Assert.IsTrue(draft.DidApply && !draft.HasChanges && draft.Error is null);
            Assert.AreEqual(NativeOptionSource.Session, target.Options.Value(NativeEncodingOption.Quality).Source);
            Assert.AreEqual(NativeOptionSource.Compiled, target.Options.Value(NativeEncodingOption.Compression).Source, "only edited fields become overrides");
            draft.SetEncoding(NativeEncodingOption.Quality, "6");
            target.Options = target.Options.Applying([new("QualityLevel", "7")], NativeOptionSource.Session);
            draft.Apply();
            Assert.IsTrue(draft.NeedsReload && draft.Error == NativeEncodingDraftError.Changed && target.Calls == 1, "a competing edit is never overwritten");
            Assert.AreEqual("6", draft.Values[NativeEncodingOption.Quality].Value);
            draft.CancelEdits();
            Assert.IsTrue(draft.NeedsReload && !draft.CanApply, "cancel never clears the conflict");
            draft.Reload();
            Assert.IsFalse(draft.NeedsReload);
            Assert.AreEqual("7", draft.Values[NativeEncodingOption.Quality].Value);
            await draft.CloseAsync();
        });
    }

    [TestMethod]
    public async Task UncertainCompletionsKeepTheDraftAndReconcile()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            foreach (var mode in new[] { Target.Behavior.FailBefore, Target.Behavior.FailAfter, Target.Behavior.SuspendBefore, Target.Behavior.SuspendAfter })
            {
                var target = new Target { Mode = mode };
                using var draft = new NativeSessionEncodingDraft(target);
                draft.Reload();
                draft.SetEncoding(NativeEncodingOption.Quality, "5");
                draft.Apply();
                var suspended = mode is Target.Behavior.SuspendBefore or Target.Behavior.SuspendAfter;
                if (suspended)
                {
                    await Until(() => target.IsSuspended, "suspended apply");
                    draft.SetEncoding(NativeEncodingOption.Quality, "8"); draft.CancelEdits(); draft.Reload(); draft.Apply();
                    Assert.AreEqual(("5", 1), (draft.Values[NativeEncodingOption.Quality].Value, target.Calls), "a pending apply gates edits, reload and a second apply");
                    draft.CancelApply();
                    target.Release();
                }
                await Until(() => !draft.IsBusy, $"{mode} completion");
                Assert.IsTrue(draft.NeedsReload && !draft.DidApply && !draft.CanApply && draft.HasChanges, $"{mode}: the draft is kept and retry is gated");
                Assert.AreEqual(suspended ? NativeEncodingDraftError.Cancelled : NativeEncodingDraftError.ApplyFailed, draft.Error, mode.ToString());
                draft.Reload();
                Assert.AreEqual(mode is Target.Behavior.FailAfter or Target.Behavior.SuspendAfter ? "5" : "3", draft.Values[NativeEncodingOption.Quality].Value,
                    $"{mode}: reload shows what actually happened");
                await draft.CloseAsync();
            }
            var early = new Target();
            using var immediate = new NativeSessionEncodingDraft(early);
            immediate.Reload(); immediate.SetEncoding(NativeEncodingOption.Quality, "5"); immediate.Apply(); immediate.CancelApply();
            await Until(() => !immediate.IsBusy, "cancel before admission");
            Assert.AreEqual((0, NativeEncodingDraftError.Cancelled), (early.Calls, immediate.Error), "an immediate cancel submits nothing");
        });
    }

    [TestMethod]
    public async Task GenerationsGuardApplyAndCloseJoinsWork()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var target = new Target();
            using var draft = new NativeSessionEncodingDraft(target);
            draft.Reload(); draft.SetEncoding(NativeEncodingOption.Quality, "5");
            target.EncodingGeneration++;
            draft.Apply();
            Assert.IsFalse(draft.CanApply);
            Assert.AreEqual(0, target.Calls, "the generation is checked before submitting");
            draft.Reload();
            target.Mode = Target.Behavior.SuspendAfter;
            draft.SetEncoding(NativeEncodingOption.Quality, "5"); draft.Apply();
            await Until(() => target.IsSuspended, "pending old generation");
            target.EncodingGeneration++;
            target.Release();
            await Until(() => !draft.IsBusy, "old completion");
            Assert.IsTrue(draft.Error == NativeEncodingDraftError.Changed && draft.NeedsReload && !draft.DidApply, "a late completion cannot confirm a new generation");

            var closing = new NativeSessionEncodingDraft(target);
            closing.Reload(); closing.SetEncoding(NativeEncodingOption.Quality, "8"); closing.Apply();
            await Until(() => target.IsSuspended, "pending close");
            var join = closing.CloseAsync();
            await Task.Delay(5);
            Assert.IsFalse(join.IsCompleted, "close waits for the accepted work");
            Assert.IsFalse(closing.CanApply);
            target.Release();
            await join;
            Assert.IsTrue(!closing.IsBusy && !closing.DidApply, "close suppresses a late confirmation");
            closing.Dispose();
        });
    }

    [TestMethod]
    public async Task RealSessionsChangeOnlyTheEditedConnection()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await using var other = new LoopbackPeer();
        await using var replacement = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            NativeSessionConfiguration Config() => new()
            {
                SecurityTypes = [1],
                Encoding = new NativeEncodingOptions([new("AutoSelect", "off"), new("QualityLevel", "3")], NativeOptionSource.AppDefaults),
            };
            var first = runtime.CreateSession(Config());
            var second = runtime.CreateSession(Config());
            await first.ConnectAsync(peer.Endpoint);
            await second.ConnectAsync(other.Endpoint);
            using var draft = new NativeSessionEncodingDraft(first);
            draft.Reload(); draft.SetEncoding(NativeEncodingOption.Quality, "5"); draft.Apply();
            await Until(() => !draft.IsBusy, "native apply");
            Assert.IsTrue(draft.DidApply && draft.Error is null, "a real completion confirms the draft");
            Assert.AreEqual(("5", "3"), (first.EncodingOptions().Value(NativeEncodingOption.Quality).Value, second.EncodingOptions().Value(NativeEncodingOption.Quality).Value));
            draft.SetEncoding(NativeEncodingOption.Quality, "7"); draft.CancelEdits();
            await first.DisconnectAsync();
            Assert.IsTrue(draft.NeedsReload && !draft.IsAvailable, "disconnect invalidates the dialog");
            await first.ConnectAsync(replacement.Endpoint);
            Assert.IsTrue(!draft.CanApply && draft.NeedsReload, "reconnecting does not revive old edits");
            draft.Reload();
            Assert.AreEqual(new NativeEncodingValue("5", NativeOptionSource.Session), draft.Values[NativeEncodingOption.Quality], "the override survives reconnecting");
            await first.CloseAsync();
            Assert.IsTrue(!draft.CanApply && !draft.IsAvailable, "close invalidates the editor");
            await draft.CloseAsync();
            await second.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }

    [TestMethod]
    public async Task TheControllerAdmitsOneEditorAndDrainsItBeforeTheNext()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-editor-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var ui = new SingleThreadDispatcher();
            await using var peer = new LoopbackPeer();
            await using var replacement = new LoopbackPeer();
            using var preferences = new NativePreferencesStore(Path.Combine(root, "state"));
            await ui.InvokeAsync(async () =>
            {
                var runtime = new NativeRuntime(ui);
                using var controller = new NativeConnectionController(new NativeConnectionServices(runtime, preferences));
                await Until(() => controller.Defaults.IsReady, "defaults");
                controller.Endpoint = peer.Endpoint;
                controller.Connect();
                await Until(() => !controller.Busy && controller.Session!.Snapshot.State == NativeSessionState.Connected, "connect");
                Assert.IsTrue(controller.EditorsIdle);
                var draft = new NativeSessionEncodingDraft(controller.Session!);
                var closed = new TaskCompletionSource();
                Assert.IsTrue(controller.BeginEditor(draft, NativeEditorScope.Connected, async () => { await draft.CloseAsync(); closed.TrySetResult(); }));
                Assert.IsFalse(controller.BeginEditor(new object(), NativeEditorScope.Any, () => Task.CompletedTask), "one editor per connection");
                Assert.IsFalse(controller.CanConnect && controller.EditorsIdle);
                draft.Reload(); draft.SetEncoding(NativeEncodingOption.Quality, "5"); draft.Apply();
                controller.EndEditor(draft);
                Assert.IsNull(controller.Editor);
                Assert.IsFalse(controller.EditorsIdle, "reopening waits until the cancelled apply has drained");
                await Until(() => controller.EditorsIdle, "drain");
                var next = new NativeSessionEncodingDraft(controller.Session!);
                Assert.IsTrue(controller.BeginEditor(next, NativeEditorScope.Connected, next.CloseAsync), "a fresh editor after the drain");
                controller.Disconnect();
                await Until(() => !controller.Busy, "disconnect");
                Assert.IsNull(controller.Editor, "disconnecting closes a connected-only editor");
                controller.Endpoint = replacement.Endpoint;
                controller.Connect();
                await Until(() => !controller.Busy, "reconnect");
                var last = new NativeSessionEncodingDraft(controller.Session!);
                controller.BeginEditor(last, NativeEditorScope.Connected, last.CloseAsync);
                await controller.CloseAsync();
                Assert.IsTrue(controller.Closing && controller.Editor is null && controller.Session!.IsClosing, "window close ends the editor and the session");
                draft.Dispose(); next.Dispose(); last.Dispose();
                await runtime.ShutdownAsync();
                return 0;
            });
            await preferences.CloseAsync();
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
