// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// Process start-up logging (tidyvnc_logging_*; NativeProcessLogging on
/// macOS; SERVICES.md section 14). The policy comes from the last Log
/// parameter of the launch (default "*:stderr:30") and is committed once,
/// before the first runtime exists. Validation never opens anything.
/// </summary>
public static unsafe class NativeProcessLogging
{
    public const string DefaultPolicy = "*:stderr:30";

    public static void Validate(string policy)
    {
        var bytes = NativeText.Utf8(policy);
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes) Abi.Check(NativeMethods.tidyvnc_logging_validate(NativeText.Span(p, bytes.Length), &error), &error);
    }

    /// <summary>The effective policy: every Log value is validated, the last one wins.</summary>
    public static string Selection(NativeInvocation invocation)
    {
        var selected = DefaultPolicy;
        foreach (var field in invocation.Assignments.Where(a => string.Equals(a.Name, "Log", StringComparison.OrdinalIgnoreCase)))
        {
            try { Validate(field.Value); }
            catch (NativeError error)
            {
                throw new NativeInvocationFailure(error.Status == NativeStatus.Unsupported
                    ? NativeInvocationFailure.Problem.Unavailable : NativeInvocationFailure.Problem.InvalidValue, field.Argument);
            }
            selected = field.Value;
        }
        return selected;
    }

    /// <summary>Commits the policy for this process; later calls fail (the core freezes it at the first runtime).</summary>
    public static void Configure(string policy)
    {
        var bytes = NativeText.Utf8(policy);
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes) Abi.Check(NativeMethods.tidyvnc_logging_configure(NativeText.Span(p, bytes.Length), &error), &error);
    }

    /// <summary>The same, with the "file" target at an explicit absolute path (isolated test roots).</summary>
    public static void Configure(string policy, string file)
    {
        var bytes = NativeText.Utf8(policy);
        var path = NativeText.Utf8(file);
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes) fixed (byte* f = path)
            Abi.Check(NativeMethods.tidyvnc_logging_configure_with_file(NativeText.Span(p, bytes.Length), NativeText.Span(f, path.Length), &error), &error);
    }

    /// <summary>
    /// Where the "file" target writes (the retained viewer's order: %TMP%,
    /// %TEMP%, %USERPROFILE%, then C:\), for the Help window. Display only;
    /// the core decides and validates the path itself.
    /// </summary>
    public static string DefaultFilePath
    {
        get
        {
            foreach (var name in new[] { "TMP", "TEMP", "USERPROFILE" })
            {
                var directory = Environment.GetEnvironmentVariable(name)?.TrimEnd('\\', '/');
                if (!string.IsNullOrEmpty(directory) && Path.IsPathFullyQualified(directory + "\\")) return directory + "\\vncviewer.log";
            }
            return "C:\\vncviewer.log";
        }
    }
}

/// <summary>The only links the app opens (SERVICES.md section 14): fixed project URLs, never text from a server or file.</summary>
public enum NativeHelpLink { Project, Issues }

public static class NativeHelpLinks
{
    public static Uri For(NativeHelpLink link) => link switch
    {
        NativeHelpLink.Project => new Uri("https://github.com/jkeli/tidyvnc"),
        NativeHelpLink.Issues => new Uri("https://github.com/jkeli/tidyvnc/issues"),
        _ => throw new ArgumentOutOfRangeException(nameof(link)),
    };
}
