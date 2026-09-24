// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Tests;

/// <summary>
/// vncviewer.exe's terminal decisions (D9, TODO W0.10): the macOS
/// invocation-terminal cases through the launcher's own sequence (parse, Log
/// targets, help/version, launch check) without starting any process. Each
/// case must end in the terminal with the retained status; none may reach
/// TidyVNC.exe. tests/integration/windows-invocation-terminal.py runs the same
/// cases through the real executable in cmd.exe and PowerShell.
/// </summary>
[TestClass]
public sealed class InvocationLaunchCheckTests
{
    private static readonly Dictionary<string, string> Environment = new(StringComparer.OrdinalIgnoreCase)
    {
        ["VNC_USERNAME"] = "private-fixture",
        ["VNC_PASSWORD"] = string.Concat(Enumerable.Repeat("private-env-", 500)),
        ["VNC_VIA_CMD"] = "private-shell",
    };

    /// <summary>The launcher's outcome: exit status and terminal text, or null when it would start TidyVNC.exe.</summary>
    private static (int Code, string Text)? Terminal(string[] arguments, IReadOnlyDictionary<string, string> environment)
    {
        NativeInvocation invocation;
        try { invocation = NativeInvocation.Parse(arguments); }
        catch (NativeInvocationFailure failure) { return (1, failure.Message); }
        if (NativeInvocationLaunchCheck.LogProblem(invocation) is { } logging) return (1, logging);
        if (NativeInvocationTerminal.For(invocation) is { } terminal) return (terminal.ExitCode, terminal.Text);
        return NativeInvocationLaunchCheck.LaunchProblem(invocation, arguments, Path.GetTempPath(), name => environment.GetValueOrDefault(name)) is { } problem
            ? (1, problem) : null;
    }

    [TestMethod]
    [DataRow(new[] { "--help" }, 1, "Usage:")]
    [DataRow(new[] { "-AlertOnFatalError=off", "--help" }, 1, "Usage:")]
    [DataRow(new[] { "-AlertOnFatalError=private", "-AlertOnFatalError=off" }, 1, "invalid value")]
    [DataRow(new[] { "-AlertOnFatalError=off" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "-AlertOnFatalError=on" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "--version" }, 0, "TidyVNC v")]
    [DataRow(new[] { "-Shared=private-value", "--help" }, 1, "invalid value")]
    [DataRow(new[] { "--unknown=private-value" }, 1, "unrecognized")]
    [DataRow(new[] { "-passwd=C:\\private-fixture-path", "--help" }, 1, "Usage:")]
    [DataRow(new[] { "C:\\private-fixture-path", "--version" }, 0, "TidyVNC v")]
    [DataRow(new[] { "-SecurityTypes=VncAuth", "127.0.0.1::5900" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "-listen" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "-listen", "65536" }, 1, "listen port must")]
    [DataRow(new[] { "-listen", "5500private-value" }, 1, "listen port must")]
    [DataRow(new[] { "-listen", ".\\private-file" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "-listen", "-UseIPv4=off", "-UseIPv6=off" }, 1, "cannot be applied")]
    [DataRow(new[] { "-via=private invalid" }, 1, "cannot be applied")]
    [DataRow(new[] { "-via=private-gateway" }, 1, "VNC_VIA_CMD shell customizations are not supported")]
    [DataRow(new[] { "-via=private-gateway", "-listen", ".\\private-file" }, 1, "cannot be combined with listening")]
    [DataRow(new[] { "-via=private-gateway", "-via=" }, 1, "launch credential exceeds")]
    [DataRow(new[] { "-Log=private-writer:private-target:2147483648", "-Log=*::0", "--help" }, 1, "invalid value")]
    [DataRow(new[] { "-Log=*:stderr:+30tail", "--version" }, 0, "TidyVNC v")]
    [DataRow(new[] { "-Log=private:stderr:30", "-Log=*::0", "--help" }, 1, "cannot be applied")]
    [DataRow(new[] { "-Log=*:file:30", "--help" }, 1, "Usage:")]
    [DataRow(new[] { "-Log=*:syslog:30", "--help" }, 1, "native adapter")]
    [DataRow(new[] { "-geometry=bad", "-geometry=800x600", "C:\\private-fixture-path" }, 1, "cannot be applied")]
    [DataRow(new[] { "-geometry=2147483648x1" }, 1, "cannot be applied")]
    [DataRow(new[] { "-Maximize=private-value", "--help" }, 1, "invalid value")]
    [DataRow(new[] { "-geometry=800x600", "-Maximize", "--version" }, 0, "TidyVNC v")]
    [DataRow(new[] { "private-host::0" }, 1, "address is invalid")]
    public void TheMacOSTerminalCasesEndInTheTerminal(string[] arguments, int code, string expected)
    {
        var outcome = Terminal(arguments, Environment);
        Assert.IsNotNull(outcome, $"{string.Join(' ', arguments)} would start TidyVNC.exe");
        Assert.AreEqual(code, outcome.Value.Code, outcome.Value.Text);
        StringAssert.Contains(outcome.Value.Text, expected);
        Assert.IsFalse(outcome.Value.Text.Contains("private-", StringComparison.Ordinal), "input is never reflected");
    }

    [TestMethod]
    public void ArgumentsBeyondTheByteLimitEndInTheTerminal()
    {
        // The macOS 65,537-byte case: a Windows command line cannot carry it (32,767 characters), so it is checked here.
        var outcome = Terminal(["-Shared", new string('A', 65537)], Environment);
        Assert.IsNotNull(outcome);
        Assert.AreEqual(1, outcome.Value.Code);
        StringAssert.Contains(outcome.Value.Text, "byte limit");
    }

    [TestMethod]
    public void UsableLaunchesStartTheApp()
    {
        var clean = new Dictionary<string, string>();
        Assert.IsNull(Terminal([], clean), "no arguments: a connection form");
        Assert.IsNull(Terminal(["127.0.0.1::5900"], clean));
        Assert.IsNull(Terminal(["-listen", "5500"], clean));
        Assert.IsNull(Terminal(["-via=user@gateway", "server::5900"], clean), "SSH forwarding without VNC_VIA_CMD");
        Assert.IsNull(Terminal(["-FullScreenSelectedMonitors=2"], clean), "monitor numbers wait for the app's displays");
        Assert.IsNull(Terminal(["127.0.0.1::5900"], new Dictionary<string, string> { ["VNC_PASSWORD"] = new string('x', 4096) }),
            "a credential at the limit");
        Assert.IsNotNull(Terminal(["127.0.0.1::5900"], new Dictionary<string, string> { ["VNC_PASSWORD"] = new string('x', 4097) }),
            "one byte over");
        Assert.IsNotNull(Terminal(["127.0.0.1::5900"], new Dictionary<string, string> { ["VNC_USERNAME"] = "a\0b" }), "a NUL");
    }
}
