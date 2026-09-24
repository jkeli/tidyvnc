// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using TidyVNC.Native.Tunnel;

namespace TidyVNC.SshAskpass;

/// <summary>
/// Started by ssh.exe, never by users:
///   tidyvnc-ssh-askpass.exe "prompt text"            (SSH_ASKPASS)
///   tidyvnc-ssh-askpass.exe --known-hosts I H T K    (KnownHostsCommand %I %H %t %K)
/// It reads the pipe name, token and owner process from its environment,
/// refuses a pipe served by any other process, and writes only the answer
/// line to standard output. It prints nothing for host key observations, so
/// OpenSSH continues its ordinary known_hosts lookup. Errors are fixed text.
/// </summary>
internal static partial class Program
{
    private const string OwnerVariable = "TIDYVNC_ASKPASS_OWNER";

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeServerProcessId(nint pipe, out uint processId);

    private static int Fail(string message)
    {
        Console.Error.WriteLine("tidyvnc-ssh-askpass: " + message);
        return 1;
    }

    private static int Main(string[] args)
    {
        var pipeName = Environment.GetEnvironmentVariable(NativeSshAskpassProtocol.PipeVariable);
        var tokenText = Environment.GetEnvironmentVariable(NativeSshAskpassProtocol.TokenVariable);
        var ownerText = Environment.GetEnvironmentVariable(OwnerVariable);
        byte[] token;
        try { token = Convert.FromHexString(tokenText ?? ""); }
        catch (FormatException) { return Fail("not started by TidyVNC"); }
        if (string.IsNullOrEmpty(pipeName) || pipeName.Length > 128 || token.Length != NativeSshAskpassProtocol.TokenBytes ||
            !uint.TryParse(ownerText, out var owner))
            return Fail("not started by TidyVNC");

        NativeSshAskpassProtocol.Kind kind;
        List<string> fields;
        if (args.Length == 5 && args[0] == "--known-hosts")
        {
            kind = NativeSshAskpassProtocol.Kind.HostKey;
            // Reason (ORDER, HOSTNAME or ADDRESS), lookup host name, key type, base64 key.
            fields = [args[1], args[2], args[3], args[4]];
        }
        else if (args.Length <= 1)
        {
            kind = NativeSshAskpassProtocol.Kind.Prompt;
            // OpenSSH sets SSH_ASKPASS_PROMPT=confirm for yes/no questions and "none" for notices.
            fields = [args.Length == 1 ? args[0] : "", Environment.GetEnvironmentVariable("SSH_ASKPASS_PROMPT") ?? ""];
        }
        else return Fail("unexpected arguments");

        byte[]? answer = null;
        try
        {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.None);
            pipe.Connect(5000);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var server) || server != owner)
                return Fail("the prompt channel is not owned by TidyVNC");
            byte[] request;
            try { request = NativeSshAskpassProtocol.EncodeRequest(kind, token, fields); }
            catch (ArgumentException) { return Fail("the prompt is too long"); }
            pipe.Write(request);
            pipe.Flush();
            answer = NativeSshAskpassProtocol.DecodeResponse(pipe);
            if (answer is null) return 1; // Cancelled: OpenSSH treats a failed askpass as no answer.
            if (kind == NativeSshAskpassProtocol.Kind.HostKey) return 0;
            using var output = Console.OpenStandardOutput();
            output.Write(answer);
            output.Write("\n"u8);
            output.Flush();
            return 0;
        }
        catch (Exception error) when (error is IOException or TimeoutException or InvalidDataException or UnauthorizedAccessException)
        {
            return Fail("the prompt channel is unavailable");
        }
        finally
        {
            if (answer is not null) CryptographicOperations.ZeroMemory(answer);
            CryptographicOperations.ZeroMemory(token);
        }
    }
}
