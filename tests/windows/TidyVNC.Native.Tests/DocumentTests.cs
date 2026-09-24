// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using TidyVNC.Native.Documents;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Documents (plans/native-ui-winui TODO W4.4, SERVICES.md section 4): the
/// shared codec through .NET, bounded reads, atomic saves with overwrite and
/// change detection, and launch routing. The Common Item Dialog itself is
/// exercised by the gated UI suite.
/// </summary>
[TestClass]
public sealed class DocumentTests
{
    private string root = "";

    [TestInitialize]
    public void Setup()
    {
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-documents-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Teardown()
    {
        foreach (var directory in Directory.EnumerateDirectories(root))
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) Directory.Delete(directory);
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(root, recursive: true);
    }

    private static async Task<NativeDocumentSaveError> SaveFailure(Func<Task> body)
    {
        try { await body(); }
        catch (NativeDocumentSaveException error) { return error.Error; }
        Assert.Fail("Expected a save failure");
        return default;
    }

    private static async Task<NativeDocumentOpenError> OpenFailure(Func<Task> body)
    {
        try { await body(); }
        catch (NativeDocumentOpenException error) { return error.Error; }
        Assert.Fail("Expected an open failure");
        return default;
    }

    [TestMethod]
    public void TheCodecParsesValidatesAndSerializesThroughTheCore()
    {
        var bytes = NativeConnectionDocument.Serialize([new("ServerName", "desk.example::5901"), new("Shared", "1")]);
        var text = Encoding.UTF8.GetString(bytes);
        StringAssert.StartsWith(text, "TidyVNC Configuration file Version 1.0\n");
        Assert.IsFalse(text.Contains('\r', StringComparison.Ordinal), "LF endings");
        using var document = new NativeConnectionDocument(bytes);
        Assert.IsFalse(document.IsLegacy);
        Assert.AreEqual(2, document.Entries.Count);
        Assert.AreEqual("ServerName", document.Entries[0].Name);
        Assert.AreEqual("desk.example::5901", document.DecodedValue(0));
        Assert.AreEqual(new NativeDocumentAssignment("Shared", "on"), document.ValidatedOption(1));

        using var legacy = new NativeConnectionDocument(Encoding.UTF8.GetBytes("TigerVNC Configuration file Version 1.0\r\nServerName=h\r\nFuture=1\r\n"));
        Assert.IsTrue(legacy.IsLegacy);
        Assert.IsNull(legacy.ValidatedOption(1), "unknown fields are not options");

        using (var invalid = new NativeConnectionDocument("TidyVNC Configuration file Version 1.0\nShared=maybe\n"u8))
            Assert.AreEqual(NativeDocumentProblem.InvalidValue, Assert.ThrowsExactly<NativeDocumentFailure>(() => invalid.ValidatedOption(0)).Problem);
        Assert.AreEqual(NativeDocumentProblem.InvalidText,
            Assert.ThrowsExactly<NativeDocumentFailure>(() => new NativeConnectionDocument([.. "TidyVNC Configuration file Version 1.0\n# "u8, 0xff, 10])).Problem);
        Assert.AreEqual(NativeDocumentProblem.InvalidHeader,
            Assert.ThrowsExactly<NativeDocumentFailure>(() => new NativeConnectionDocument("Something else\n"u8)).Problem);
        Assert.AreEqual(NativeDocumentProblem.TooLarge,
            Assert.ThrowsExactly<NativeDocumentFailure>(() => new NativeConnectionDocument(new byte[NativeConnectionDocument.MaximumBytes + 1])).Problem);
        Assert.AreEqual(NativeDocumentProblem.InvalidExportName,
            Assert.ThrowsExactly<NativeDocumentFailure>(() => NativeConnectionDocument.Serialize([new("Password", "x")])).Problem);
        Assert.AreEqual(NativeDocumentProblem.LineTooLong,
            Assert.ThrowsExactly<NativeDocumentFailure>(() => NativeConnectionDocument.Serialize([new("ServerName", new string('x', 256))])).Problem);
    }

    [TestMethod]
    public async Task ReadsAreBoundedAndRefuseSpecialFiles()
    {
        var reader = new NativeDocumentFileReader();
        var file = Path.Combine(root, "desk.tidyvnc");
        var bytes = NativeConnectionDocument.Serialize([new("ServerName", "desk")]);
        await File.WriteAllBytesAsync(file, bytes);
        CollectionAssert.AreEqual(bytes, await reader.ReadAsync(file, default));
        var large = Path.Combine(root, "large.tidyvnc");
        await File.WriteAllBytesAsync(large, new byte[NativeConnectionDocument.MaximumBytes + 1]);
        Assert.AreEqual(NativeDocumentOpenError.TooLarge, await OpenFailure(() => reader.ReadAsync(large, default)));
        Assert.AreEqual(NativeDocumentOpenError.Unreadable, await OpenFailure(() => reader.ReadAsync(Path.Combine(root, "missing.tidyvnc"), default)));
        Assert.AreEqual(NativeDocumentOpenError.Unreadable, await OpenFailure(() => reader.ReadAsync("relative.tidyvnc", default)));
        Assert.AreEqual(NativeDocumentOpenError.NotRegular, await OpenFailure(() => reader.ReadAsync(root, default)));
        Assert.AreEqual(NativeDocumentOpenError.NotRegular, await OpenFailure(() => reader.ReadAsync(@"\\.\NUL", default)));
        var pipeName = "tidyvnc-test-" + Guid.NewGuid().ToString("N");
        await using (var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
        {
            _ = pipe.WaitForConnectionAsync();
            Assert.AreEqual(NativeDocumentOpenError.NotRegular, await OpenFailure(() => reader.ReadAsync(@"\\.\pipe\" + pipeName, default)));
        }
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        Assert.AreEqual(NativeDocumentOpenError.Cancelled, await OpenFailure(() => reader.ReadAsync(file, cancelled.Token)));
    }

    [TestMethod]
    public async Task SavesAreAtomicAndDetectChangesSinceTheDialog()
    {
        var writer = new NativeDocumentFileWriter();
        var path = Path.Combine(root, "desk.tidyvnc");
        var first = NativeConnectionDocument.Serialize([new("ServerName", "one")]);
        var second = NativeConnectionDocument.Serialize([new("ServerName", "two")]);

        var fresh = await writer.PrepareAsync(path);
        Assert.IsFalse(fresh.Exists);
        await writer.WriteAsync(first, fresh, overwrite: false);
        CollectionAssert.AreEqual(first, await File.ReadAllBytesAsync(path));
        Assert.AreEqual(NativeDocumentSaveError.Changed, await SaveFailure(() => writer.WriteAsync(second, fresh, overwrite: false)),
            "a file created after the dialog is never replaced");

        var existing = await writer.PrepareAsync(path);
        Assert.IsTrue(existing.Exists);
        Assert.AreEqual(NativeDocumentSaveError.OverwriteRequired, await SaveFailure(() => writer.WriteAsync(second, existing, overwrite: false)));
        await writer.WriteAsync(second, existing, overwrite: true);
        CollectionAssert.AreEqual(second, await File.ReadAllBytesAsync(path));
        Assert.AreEqual(NativeDocumentSaveError.Changed, await SaveFailure(() => writer.WriteAsync(first, existing, overwrite: true)),
            "the destination changed after it was chosen");
        var foreign = await writer.PrepareAsync(path);
        Assert.AreEqual(NativeDocumentSaveError.Changed, await SaveFailure(() => new NativeDocumentFileWriter().WriteAsync(first, foreign, overwrite: true)),
            "destinations belong to their writer");
        Assert.IsFalse(Directory.EnumerateFiles(root, "*.tmp").Any(), "no temporaries remain");
    }

    [TestMethod]
    public async Task InvalidDestinationsAreRefusedBeforeAnyWrite()
    {
        var writer = new NativeDocumentFileWriter();
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync(Path.Combine(root, "desk.txt"))));
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync("desk.tidyvnc")));
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync(Path.Combine(root, "missing", "desk.tidyvnc"))));
        Directory.CreateDirectory(Path.Combine(root, "folder.tidyvnc"));
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync(Path.Combine(root, "folder.tidyvnc"))));

        var target = Path.Combine(root, "target.tidyvnc");
        await File.WriteAllTextAsync(target, "x");
        var linked = Path.Combine(root, "linked.tidyvnc");
        using (var mklink = Process.Start(new ProcessStartInfo("cmd.exe", ["/d", "/c", "mklink", "/H", linked, target])
               { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!)
            await mklink.WaitForExitAsync();
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync(linked)), "hard links are not replaced");

        var junction = Path.Combine(root, "junction");
        using (var mklink = Process.Start(new ProcessStartInfo("cmd.exe", ["/d", "/c", "mklink", "/J", junction, root])
               { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!)
            await mklink.WaitForExitAsync();
        Assert.AreEqual(NativeDocumentSaveError.InvalidDestination, await SaveFailure(() => writer.PrepareAsync(Path.Combine(junction, "desk.tidyvnc"))),
            "a redirected folder is refused");

        var readOnly = Path.Combine(root, "readonly.tidyvnc");
        await File.WriteAllTextAsync(readOnly, "x");
        File.SetAttributes(readOnly, FileAttributes.ReadOnly);
        Assert.AreEqual(NativeDocumentSaveError.Denied, await SaveFailure(() => writer.PrepareAsync(readOnly)));
    }

    [TestMethod]
    public async Task ChangesBetweenWriteAndReplaceAndFailuresAfterCommitAreTyped()
    {
        var path = Path.Combine(root, "desk.tidyvnc");
        var data = NativeConnectionDocument.Serialize([new("ServerName", "desk")]);
        await File.WriteAllTextAsync(path, "original");

        var racing = new NativeDocumentFileWriter(stage => { if (stage == "willReplace") File.WriteAllText(path, "edited elsewhere"); });
        Assert.AreEqual(NativeDocumentSaveError.Changed, await SaveFailure(async () => await racing.WriteAsync(data, await racing.PrepareAsync(path), overwrite: true)));
        Assert.AreEqual("edited elsewhere", await File.ReadAllTextAsync(path));

        var failing = new NativeDocumentFileWriter(stage => { if (stage == "written") throw new IOException("disk full"); });
        Assert.AreEqual(NativeDocumentSaveError.WriteFailed, await SaveFailure(async () => await failing.WriteAsync(data, await failing.PrepareAsync(path), overwrite: true)));
        Assert.AreEqual("edited elsewhere", await File.ReadAllTextAsync(path), "a failed write leaves the destination");

        var uncertain = new NativeDocumentFileWriter(stage => { if (stage == "didReplace") throw new IOException("late"); });
        Assert.AreEqual(NativeDocumentSaveError.CommittedUncertain, await SaveFailure(async () => await uncertain.WriteAsync(data, await uncertain.PrepareAsync(path), overwrite: true)));
        CollectionAssert.AreEqual(data, await File.ReadAllBytesAsync(path), "never reported as preserving the old file");
        Assert.IsFalse(Directory.EnumerateFiles(root, "*.tmp").Any());
    }

    [TestMethod]
    public async Task ConcurrentSavesToOneFolderAreSerialized()
    {
        var entered = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var slow = new NativeDocumentFileWriter(stage => { if (stage == "written") { entered.Set(); release.Wait(); } });
        var fast = new NativeDocumentFileWriter();
        var data = NativeConnectionDocument.Serialize([new("ServerName", "desk")]);
        var first = slow.WriteAsync(data, await slow.PrepareAsync(Path.Combine(root, "a.tidyvnc")), false);
        entered.Wait(TimeSpan.FromSeconds(10));
        Assert.AreEqual(NativeDocumentSaveError.Busy, await SaveFailure(async () => await fast.WriteAsync(data, await fast.PrepareAsync(Path.Combine(root, "b.tidyvnc")), false)));
        release.Set();
        await first;
        await fast.WriteAsync(data, await fast.PrepareAsync(Path.Combine(root, "b.tidyvnc")), false);
    }

    [TestMethod]
    public async Task LaunchRequestsWaitForTheWindowActionAndValidateWholeBatches()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(() =>
        {
            var router = new NativeDocumentLaunchRouter(ui);
            var opened = new List<NativeDocumentOpenRequest>();
            Assert.IsTrue(router.Route([@"C:\a.tidyvnc", @"\\server\share\b.tigervnc"], @"C:\work"));
            Assert.AreEqual(2, router.PendingCount);
            Assert.IsFalse(router.Route([@"C:\c.tidyvnc", "relative.tidyvnc"], @"C:\work"), "one bad member refuses the batch");
            Assert.AreEqual(2, router.PendingCount);
            Assert.IsFalse(router.Route([.. Enumerable.Range(0, NativeDocumentLaunchRouter.MaximumPending - 1).Select(n => $@"C:\{n}.tidyvnc")], @"C:\work"));
            router.Install(opened.Add);
            Assert.AreEqual(0, router.PendingCount);
            CollectionAssert.AreEqual(new[] { @"C:\a.tidyvnc", @"\\server\share\b.tigervnc" }, opened.Select(r => r.Path).ToArray());
            Assert.AreNotEqual(opened[0].Id, opened[1].Id);
            Assert.IsTrue(router.Route([@"C:\a.tidyvnc"], @"D:\"));
            Assert.AreEqual(3, opened.Count);
            Assert.AreNotEqual(opened[0].Id, opened[2].Id, "every explicit open is a new window");
            router.Stop();
            Assert.IsFalse(router.Route([@"C:\a.tidyvnc"], @"C:\"));
        });
    }
}
