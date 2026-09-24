// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Reflection;
using System.Text;

namespace TidyVNC.Native;

/// <summary>
/// Help and version output with the retained exit codes (help 1, version 0),
/// the Windows counterpart of NativeInvocationBootstrap.terminal in Swift. The
/// console launcher prints it; the GUI app never does (D9).
/// </summary>
public static class NativeInvocationTerminal
{
    public static string Version =>
        typeof(NativeInvocationTerminal).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(NativeInvocationTerminal).Assembly.GetName().Version?.ToString(3) ?? "0";

    /// <summary>Null for a launch; otherwise the text and exit code.</summary>
    public static (string Text, int ExitCode)? For(NativeInvocation invocation)
    {
        if (invocation.Action == NativeInvocationAction.Launch) return null;
        var text = new StringBuilder();
        text.Append("TidyVNC v").Append(Version).Append('\n').Append("Native Windows viewer\n");
        if (invocation.Action == NativeInvocationAction.Version) return (text.ToString(), 0);
        text.Append("""

            Usage: vncviewer [parameters] [host][:display]
                   vncviewer [parameters] [host][::port]
                   vncviewer [parameters] [path\to\socket]
                   vncviewer [parameters] [.\connection.tidyvnc]
                   vncviewer -listen [parameters] [port]

            -h, --help       Show this help (exit status 1, matching the retained viewer).
            -v, --version    Show the version.

            Names are case-insensitive. Enable a boolean with -Name; disable it with
            -Name=off. Values accept -Name value, Name=value, -Name=value or --Name=value.
            Use .\ before a relative file name; a bare name is a server address.
            Explicit files override CLI settings and open for review before connecting.
            With no server address, a connection form opens.

            Parameters (unavailable entries cannot be used):

            """.Replace("\r\n", "\n", StringComparison.Ordinal));
        foreach (var option in NativeInvocation.Options())
        {
            text.Append("  ").Append(option.Name).Append(option.Boolean ? " [on|off]" : " <value>");
            if (option.Alias.Length > 0) text.Append(" (alias: ").Append(option.Alias).Append(')');
            if (!option.Available) text.Append(" [unavailable]");
            text.Append('\n');
        }
        return (text.ToString(), 1);
    }
}
