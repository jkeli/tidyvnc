// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Activation;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Activation rules (plans/native-ui-winui TODO W4.10, SERVICES.md
/// section 12): what a launch asks for, command-line splitting, the
/// vncviewer.exe marker and the Jump List. Primary-instance redirection
/// between real processes is exercised by the gated UI suite.
/// </summary>
[TestClass]
public sealed class ActivationTests
{
    private static NativeActivationRequest Classify(string? workingDirectory, params string[] arguments) => NativeActivation.Classify(arguments, workingDirectory);

    [TestMethod]
    public void OperandsFollowTheRetainedViewerRules()
    {
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.NewWindow), Classify(null));
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.Address, Address: "desk.example::5901"), Classify(null, "desk.example::5901"));
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.Address, Address: "desk.tidyvnc"), Classify(@"C:\work", "desk.tidyvnc"),
            "a bare name ending in .tidyvnc is still a host");
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.Document, DocumentPath: @"C:\work\desk.tidyvnc"), Classify(@"C:\work", @".\desk.tidyvnc"));
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.Document, DocumentPath: @"D:\files\desk.tidyvnc"), Classify(null, @"D:\files\desk.tidyvnc"));
        Assert.AreEqual(new NativeActivationRequest(NativeActivationKind.Document, DocumentPath: @"\\server\share\desk.tidyvnc"), Classify(null, @"\\server\share\desk.tidyvnc"));
        Assert.AreEqual(NativeActivationKind.Invalid, Classify(null, @".\desk.tidyvnc").Kind, "a redirected relative path has no working directory");
        Assert.AreEqual(NativeActivationKind.Invalid, Classify(@"C:\work", @"\rooted.tidyvnc").Kind);
        Assert.AreEqual(NativeActivationKind.Listen, Classify(null, "-listen").Kind);
        Assert.AreEqual(NativeActivationKind.Invalid, Classify(null, "-NoSuchParameter").Kind);
        Assert.AreEqual(NativeActivationKind.Invalid, Classify(null, "--help").Kind, "help is the console launcher's job");
    }

    [TestMethod]
    public void CommandLinesSplitLikeTheCRuntime()
    {
        CollectionAssert.AreEqual(new[] { @"C:\Program Files\TidyVNC\TidyVNC.exe", @"C:\My Files\desk.tidyvnc" },
            NativeActivation.SplitCommandLine(@"""C:\Program Files\TidyVNC\TidyVNC.exe"" ""C:\My Files\desk.tidyvnc""").ToArray());
        CollectionAssert.AreEqual(new[] { "a\"b", @"c\\" }, NativeActivation.SplitCommandLine(@"x ""a\""b"" ""c\\\\""").Skip(1).ToArray());
        Assert.AreEqual(0, NativeActivation.SplitCommandLine("  ").Count);
        foreach (var argument in new[] { "plain", "two words", "quote\"inside", @"trailing\", @"C:\path with space\", "" })
        {
            var line = "exe " + TidyVNC.Native.Tunnel.NativeOwnedProcess.Quote(argument);
            Assert.AreEqual(argument, NativeActivation.SplitCommandLine(line)[1], "quoting and splitting round-trip");
        }
    }

    [TestMethod]
    public void TheCommandLineMarkerIsTakenOnce()
    {
        Environment.SetEnvironmentVariable(NativeActivation.CommandLineVariable, "1");
        Assert.IsTrue(NativeActivation.TakeCommandLineMarker());
        Assert.IsNull(Environment.GetEnvironmentVariable(NativeActivation.CommandLineVariable), "never inherited further");
        Assert.IsFalse(NativeActivation.TakeCommandLineMarker());
        Environment.SetEnvironmentVariable(NativeActivation.CommandLineVariable, "yes");
        Assert.IsFalse(NativeActivation.TakeCommandLineMarker(), "only the exact marker counts");
    }

    [TestMethod]
    public void JumpListsPublishAndDeleteForAnAppId()
    {
        // A disposable AppUserModelID, so the real TidyVNC Jump List is untouched.
        var appId = "io.github.jkeli.tidyvnc.test." + Guid.NewGuid().ToString("N")[..8];
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                NativeJumpList.Publish(appId, Environment.ProcessPath!, [new NativeJumpListTask("New connection", ""), new NativeJumpListTask("Listen", "-listen")]);
                NativeJumpList.Publish(appId, Environment.ProcessPath!, []);
                NativeJumpList.Delete(appId);
                Assert.ThrowsExactly<ArgumentException>(() => NativeJumpList.Publish(appId, "relative.exe", []));
            }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.IsTrue(thread.Join(TimeSpan.FromSeconds(30)));
        if (failure is not null) throw failure;
    }
}
