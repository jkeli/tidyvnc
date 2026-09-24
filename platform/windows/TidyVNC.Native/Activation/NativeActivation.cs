// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace TidyVNC.Native.Activation;

public enum NativeActivationKind
{
    /// <summary>A plain launch: open a new connection window.</summary>
    NewWindow,
    /// <summary>Open a new window for this server address (not connected until the user confirms).</summary>
    Address,
    /// <summary>Review this connection file in a new window.</summary>
    Document,
    /// <summary>Open the listener window.</summary>
    Listen,
    /// <summary>The arguments were not a valid launch; open a new window and say so.</summary>
    Invalid,
}

public sealed record NativeActivationRequest(NativeActivationKind Kind, string? Address = null, string? DocumentPath = null)
{
    public override string ToString() => $"NativeActivationRequest({Kind})";
}

/// <summary>
/// Activation rules (SERVICES.md section 12, DECISIONS.md D8/D9). Shell
/// launches (Start menu, Explorer file opens, Jump List tasks) go to one
/// primary process; command-line launches through vncviewer.exe are marked
/// by an inherited environment variable, run in their own process and never
/// redirect or register. Operands follow the retained viewer: one containing
/// \ or / is a file path, anything else (including "desk.tidyvnc") is a
/// server address.
/// </summary>
public static unsafe class NativeActivation
{
    /// <summary>The AppUserModelID shared by the process, shortcut, taskbar grouping and Jump List.</summary>
    public const string AppUserModelId = "io.github.jkeli.tidyvnc";
    /// <summary>Set by vncviewer.exe for the TidyVNC.exe it starts; read and cleared once at start-up.</summary>
    public const string CommandLineVariable = "TIDYVNC_COMMAND_LINE";

    /// <summary>True for a vncviewer.exe launch; removes the marker so it is never inherited further.</summary>
    public static bool TakeCommandLineMarker()
    {
        var marked = Environment.GetEnvironmentVariable(CommandLineVariable) == "1";
        Environment.SetEnvironmentVariable(CommandLineVariable, null);
        return marked;
    }

    public static void ApplyAppUserModelId()
    {
        fixed (char* id = AppUserModelId) PInvoke.SetCurrentProcessExplicitAppUserModelID(id).ThrowOnFailure();
    }

    /// <summary>Splits a command line exactly as the C runtime does (CommandLineToArgvW).</summary>
    public static IReadOnlyList<string> SplitCommandLine(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return [];
        int count;
        char** arguments;
        fixed (char* text = commandLine) arguments = (char**)PInvoke.CommandLineToArgv(text, &count);
        if (arguments is null) throw new ArgumentException("Invalid command line", nameof(commandLine));
        try
        {
            var result = new string[count];
            for (var i = 0; i < count; i++) result[i] = new string(arguments[i]);
            return result;
        }
        finally
        {
            PInvoke.LocalFree(new HLOCAL(arguments));
        }
    }

    /// <summary>
    /// What a launch asks for. Shell activations (redirected to the primary)
    /// accept only fully qualified document paths, since the sender's working
    /// directory is not part of the activation.
    /// </summary>
    public static NativeActivationRequest Classify(IReadOnlyList<string> arguments, string? workingDirectory = null)
    {
        NativeInvocation invocation;
        try { invocation = NativeInvocation.Parse(arguments); }
        catch (Exception error) when (error is NativeInvocationFailure or NativeError) { return new(NativeActivationKind.Invalid); }
        if (invocation.Action != NativeInvocationAction.Launch) return new(NativeActivationKind.Invalid);
        if (invocation.Value("listen") is { } listen && listen != "off" && listen != "0") return new(NativeActivationKind.Listen);
        if (invocation.Operand is not { Length: > 0 } operand) return new(NativeActivationKind.NewWindow);
        if (!operand.Contains('\\', StringComparison.Ordinal) && !operand.Contains('/', StringComparison.Ordinal))
            return new(NativeActivationKind.Address, Address: operand);
        var path = operand;
        if (!Path.IsPathFullyQualified(path))
        {
            if (Path.IsPathRooted(path) || workingDirectory is null || !Path.IsPathFullyQualified(workingDirectory)) return new(NativeActivationKind.Invalid);
            path = Path.GetFullPath(Path.Join(workingDirectory, path));
        }
        return new(NativeActivationKind.Document, DocumentPath: path);
    }
}
