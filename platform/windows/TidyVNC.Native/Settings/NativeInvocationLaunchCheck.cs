// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Activation;
using TidyVNC.Native.Credentials;

namespace TidyVNC.Native;

/// <summary>
/// What vncviewer.exe checks before it starts TidyVNC.exe (D9; macOS
/// NativeInvocationBootstrap.terminal and .launch, then its launch-credential
/// capture): the Log targets, every command-line value against the built-in
/// defaults, the listen form, SSH routing, the server address and the
/// environment credentials. A problem is reported in the terminal with exit
/// status 1 and no window opens. Only metadata is inspected: no file contents,
/// sockets or settings stores. Messages are English, like the rest of the
/// launcher's terminal output.
/// </summary>
public static class NativeInvocationLaunchCheck
{
    public const string CustomTunnelVariable = "VNC_VIA_CMD";

    private const string NativeAdapter = "A command-line option needs a native adapter that is not available yet.";
    private const string CannotApply = "A command-line value cannot be applied to this connection.";

    /// <summary>Log targets, checked before help and version as on macOS; null when they are usable.</summary>
    public static string? LogProblem(NativeInvocation invocation)
    {
        foreach (var field in invocation.Assignments.Where(a => string.Equals(a.Name, "Log", StringComparison.OrdinalIgnoreCase)))
        {
            try { NativeProcessLogging.Validate(field.Value); }
            catch (NativeError error) { return Text(error.Status == NativeStatus.Unsupported ? NativeAdapter : CannotApply, field.Argument); }
        }
        return null;
    }

    /// <summary>The terminal message for an unusable launch, or null when TidyVNC.exe may start.</summary>
    public static string? LaunchProblem(NativeInvocation invocation, IReadOnlyList<string> arguments, string workingDirectory,
                                        Func<string, string?> environment)
    {
        if (invocation.Action != NativeInvocationAction.Launch) return null;
        try
        {
            // Every value first, before any path; monitor numbers wait for the app's displays.
            var values = new NativeInvocationLayer(invocation, "", workingDirectory);
            try { _ = NativeSessionSetup.Resolve(null, commandLine: values); }
            catch (NativeSetupFailure failure) when (failure.Problem == NativeSetupProblem.DisplayMappingRequired) { }
            if (environment(CustomTunnelVariable) is not null && values.Gateway() is not null)
                return "VNC_VIA_CMD shell customizations are not supported. Unset VNC_VIA_CMD to use native SSH forwarding.";

            if (invocation.Value("listen") == "on")
            {
                var families = invocation.Assignments.LastOrDefault(a => a.Name is "UseIPv4" or "UseIPv6");
                if (invocation.Value("UseIPv4") == "off" && invocation.Value("UseIPv6") == "off")
                    return Text(CannotApply, families?.Argument ?? 0);
                if (NativeListenerModel.Launch(invocation, workingDirectory).Invalid)
                    return Text("The listen port must be a decimal number from 0 to 65535.", invocation.OperandArgument);
            }
            else if (NativeActivation.Classify(arguments, workingDirectory) is { Kind: NativeActivationKind.Address, Address: { } endpoint })
            {
                if (NativeEndpoint.Issue(endpoint) is not null)
                    return Text("The command-line server address is invalid.", invocation.OperandArgument);
                _ = new NativeInvocationLayer(invocation, endpoint, workingDirectory).Gateway(endpoint: endpoint);
            }
        }
        catch (NativeSetupFailure failure) { return Text(Message(failure.Problem), failure.Position); }
        return CredentialProblem(environment);
    }

    /// <summary>VNC_USERNAME and VNC_PASSWORD as the app will capture them: UTF-8, at most 4096 bytes, no NUL.</summary>
    private static string? CredentialProblem(Func<string, string?> environment)
    {
        var strict = new UTF8Encoding(false, true);
        foreach (var name in new[] { NativeLaunchCredentialInputs.UsernameVariable, NativeLaunchCredentialInputs.PasswordVariable })
        {
            if (environment(name) is not { } value) continue;
            int bytes;
            try { bytes = strict.GetByteCount(value); }
            catch (EncoderFallbackException) { bytes = int.MaxValue; }
            if (bytes > NativeCredentialSecret.MaximumBytes || value.Contains('\0', StringComparison.Ordinal))
                return "A launch credential exceeds its byte limit or contains invalid data.";
        }
        return null;
    }

    private static string Message(NativeSetupProblem problem) => problem switch
    {
        NativeSetupProblem.UnsupportedOption => NativeAdapter,
        NativeSetupProblem.InvalidEndpoint => "The command-line server address is invalid.",
        NativeSetupProblem.RelativePathNeedsBase => "Resolve the command-line file path before continuing.",
        NativeSetupProblem.InvalidListenPort => "The listen port must be a decimal number from 0 to 65535.",
        NativeSetupProblem.InvalidTunnelTarget => "SSH forwarding requires a supported TCP server address. Unix socket targets are not supported.",
        NativeSetupProblem.TunnelListenUnsupported => "SSH forwarding cannot be combined with listening for connections.",
        _ => CannotApply,
    };

    private static string Text(string message, uint argument) => argument == 0 ? message : $"Argument {argument}: {message}";
}
