// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Reflection;
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// Help and version output with the retained exit codes (help 1, version 0),
/// the Windows counterpart of NativeInvocationBootstrap.terminal in Swift: the
/// same sections, defaults and notes, with Windows paths. The console launcher
/// prints it in English, as the retained viewer does; the GUI app never does (D9).
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
        text.Append(Normalize("""

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
            With no server address, a connection form opens. Native defaults use native
            stores; importing compatibility defaults/history is a separate explicit action.

            Parameters (unavailable entries cannot be used):

            """));
        var defaults = Defaults();
        foreach (var option in NativeInvocation.Options())
        {
            text.Append("  ").Append(option.Name).Append(option.Boolean ? " [on|off]" : " <value>");
            if (option.Alias.Length > 0) text.Append(" (alias: ").Append(option.Alias).Append(')');
            if (defaults.TryGetValue(option.Name, out var initial)) text.Append(" [default: ").Append(initial).Append(']');
            if (!option.Available) text.Append(" [unavailable]");
            text.Append('\n');
        }
        text.Append(Normalize("""

            AlertOnFatalError=off closes the affected connection or failed listener when no Retry action is available.
            ReconnectOnError=on still offers Retry for eligible outgoing connection errors. Other windows and the application remain open.

            Log targets: stderr, stdout, file, or empty to disable.
            File: %TMP%\vncviewer.log (else %TEMP% or %USERPROFILE%), created on first output with one .bak; failures use stderr.
            Listen defaults to TCP port 5500; port 0 chooses an available port. Use a decimal port from 0 to 65535.
            With -listen .\file.tidyvnc, review file settings before binding; ServerName supplies the port. Unix socket listeners are unsupported.
            Accept each incoming connection in the listener window.
            Legacy password files apply only to password-only authentication. VNC_PASSWORD (with VNC_USERNAME when required) takes precedence.
            Launch credentials belong to the first connection window (first accepted incoming window with -listen) and are never saved.
            Stopping the listener clears unclaimed launch credentials.
            Unsupported native adapters fail explicitly; their parameters are never ignored.
            SSH via accepts [user@]host or ssh://[user@]host[:port]. It uses Windows OpenSSH host-key verification, default-key/agent authentication and native password/passphrase prompts.
            New Ed25519/RSA/ECDSA gateway keys require explicit Trust and save; changed keys are rejected.
            Supported %USERPROFILE%\.ssh\config settings are captured before connecting; commands, proxy hops and VNC_VIA_CMD are unsupported.
            SSH forwarding cannot be used with -listen or Unix socket targets. An empty via value selects a direct connection.

            """));
        return (text.ToString(), 1);
    }

    private static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal);

    /// <summary>The core's compiled defaults, as the macOS help shows them.</summary>
    private static unsafe Dictionary<string, string> Defaults()
    {
        var defaults = NativeEncodingOptions.Schema().ToDictionary(s => s.Name, s => s.DefaultValue, StringComparer.Ordinal);
        var error = Abi.Init<tidyvnc_error>();
        var limits = Abi.Init<tidyvnc_message_limits>();
        Abi.Check(NativeMethods.tidyvnc_message_limits_init(&limits, &error), &error);
        defaults["MaxCutText"] = limits.max_cut_text.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var timing = Abi.Init<tidyvnc_input_timing>();
        Abi.Check(NativeMethods.tidyvnc_input_timing_init(&timing, &error), &error);
        defaults["PointerEventInterval"] = timing.pointer_interval_ms.ToString(System.Globalization.CultureInfo.InvariantCulture);
        defaults["Log"] = NativeProcessLogging.DefaultPolicy;
        return defaults;
    }
}
