// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security;
using Windows.Win32.System.JobObjects;
using Windows.Win32.System.Threading;

namespace TidyVNC.Native.Tunnel;

public sealed class NativeProcessException(string message, int nativeCode = 0) : Exception(message)
{
    public int NativeCode { get; } = nativeCode;
}

/// <summary>
/// One child process owned the way SERVICES.md section 11 requires:
/// CreateProcessW with an explicit argument vector (quoted by the CRT rules,
/// never a shell string), an explicit environment block, handle inheritance
/// limited to its three pipes, and membership of a Job Object from creation
/// (PROC_THREAD_ATTRIBUTE_JOB_LIST, so no descendant escapes) that kills the
/// whole tree when the owner closes. Standard streams are pipes the owner
/// reads and writes; the process never gets a console window.
/// </summary>
public sealed unsafe class NativeOwnedProcess : IDisposable
{
    private const nuint HandleListAttribute = 0x00020002; // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
    private const nuint JobListAttribute = 0x0002000D;    // PROC_THREAD_ATTRIBUTE_JOB_LIST

    private readonly SafeFileHandle job, process;
    private readonly TaskCompletionSource<int> exited = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly RegisteredWaitHandle exitWait;
    private readonly ManualResetEvent processEvent;
    private bool disposed;

    public int Id { get; }
    /// <summary>The child's standard input (owner writes).</summary>
    public FileStream Input { get; }
    /// <summary>The child's standard output (owner reads).</summary>
    public FileStream Output { get; }
    /// <summary>The child's standard error (owner reads).</summary>
    public FileStream Error { get; }
    /// <summary>Completes with the exit code when the process exits.</summary>
    public Task<int> Exited => exited.Task;

    private NativeOwnedProcess(SafeFileHandle job, SafeFileHandle process, int id, FileStream input, FileStream output, FileStream error)
    {
        this.job = job;
        this.process = process;
        Id = id;
        Input = input;
        Output = output;
        Error = error;
        processEvent = new ManualResetEvent(false) { SafeWaitHandle = new SafeWaitHandle(process.DangerousGetHandle(), ownsHandle: false) };
        exitWait = ThreadPool.RegisterWaitForSingleObject(processEvent, (_, _) =>
        {
            uint code = 0;
            PInvoke.GetExitCodeProcess(process, out code);
            exited.TrySetResult(unchecked((int)code));
        }, null, Timeout.Infinite, executeOnlyOnce: true);
    }

    /// <summary>Quotes one argument for CommandLineToArgvW / the MSVC runtime.</summary>
    public static string Quote(string argument)
    {
        if (argument.Contains('\0', StringComparison.Ordinal)) throw new ArgumentException("NUL in argument", nameof(argument));
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0) return argument;
        var quoted = new StringBuilder("\"");
        for (var i = 0; ; i++)
        {
            var backslashes = 0;
            while (i < argument.Length && argument[i] == '\\') { i++; backslashes++; }
            if (i == argument.Length)
            {
                quoted.Append('\\', backslashes * 2);
                break;
            }
            if (argument[i] == '"')
            {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
            }
            else
            {
                quoted.Append('\\', backslashes);
                quoted.Append(argument[i]);
            }
        }
        return quoted.Append('"').ToString();
    }

    private static void Pipe(out SafeFileHandle read, out SafeFileHandle write, bool childReads)
    {
        var attributes = new SECURITY_ATTRIBUTES { nLength = (uint)sizeof(SECURITY_ATTRIBUTES), bInheritHandle = true };
        if (!PInvoke.CreatePipe(out read, out write, attributes, 0)) throw new NativeProcessException("Creating a pipe failed", Marshal.GetLastPInvokeError());
        // Only the child's end is inheritable (and even then only through the handle list).
        var parent = childReads ? write : read;
        PInvoke.SetHandleInformation(parent, (uint)HANDLE_FLAGS.HANDLE_FLAG_INHERIT, 0);
    }

    /// <summary>
    /// Starts executable with arguments and exactly the given environment.
    /// The executable must be a fully qualified path.
    /// </summary>
    public static NativeOwnedProcess Start(string executable, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment)
    {
        if (!Path.IsPathFullyQualified(executable)) throw new ArgumentException("The executable needs a full path", nameof(executable));
        var commandLine = string.Join(' ', new[] { executable }.Concat(arguments).Select(Quote));
        if (commandLine.Length >= 32767) throw new ArgumentException("Command line too long", nameof(arguments));
        var block = new StringBuilder();
        foreach (var (name, value) in environment.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (name.Length == 0 || name.Contains('=', StringComparison.Ordinal) || name.Contains('\0', StringComparison.Ordinal) || value.Contains('\0', StringComparison.Ordinal))
                throw new ArgumentException("Invalid environment entry", nameof(environment));
            block.Append(name).Append('=').Append(value).Append('\0');
        }
        block.Append('\0');

        var jobHandle = PInvoke.CreateJobObject(null, (string?)null);
        if (jobHandle.IsInvalid) throw new NativeProcessException("Creating a job failed", Marshal.GetLastPInvokeError());
        SafeFileHandle? inRead = null, inWrite = null, outRead = null, outWrite = null, errRead = null, errWrite = null;
        try
        {
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
            if (!PInvoke.SetInformationJobObject((HANDLE)jobHandle.DangerousGetHandle(), JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation, &limits, (uint)sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))
                throw new NativeProcessException("Configuring the job failed", Marshal.GetLastPInvokeError());

            Pipe(out inRead, out inWrite, childReads: true);
            Pipe(out outRead, out outWrite, childReads: false);
            Pipe(out errRead, out errWrite, childReads: false);

            nuint size = 0;
            PInvoke.InitializeProcThreadAttributeList(default, 2, 0, &size);
            var attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)NativeMemory.Alloc(size);
            var inherited = stackalloc HANDLE[3];
            inherited[0] = (HANDLE)inRead.DangerousGetHandle();
            inherited[1] = (HANDLE)outWrite.DangerousGetHandle();
            inherited[2] = (HANDLE)errWrite.DangerousGetHandle();
            var jobs = stackalloc HANDLE[1];
            jobs[0] = (HANDLE)jobHandle.DangerousGetHandle();
            try
            {
                if (!PInvoke.InitializeProcThreadAttributeList(attributes, 2, 0, &size) ||
                    !PInvoke.UpdateProcThreadAttribute(attributes, 0, HandleListAttribute, inherited, (nuint)(3 * sizeof(HANDLE)), null, (nuint*)null) ||
                    !PInvoke.UpdateProcThreadAttribute(attributes, 0, JobListAttribute, jobs, (nuint)sizeof(HANDLE), null, (nuint*)null))
                    throw new NativeProcessException("Preparing the process failed", Marshal.GetLastPInvokeError());
                var startup = new STARTUPINFOEXW();
                startup.StartupInfo.cb = (uint)sizeof(STARTUPINFOEXW);
                startup.StartupInfo.dwFlags = STARTUPINFOW_FLAGS.STARTF_USESTDHANDLES;
                startup.StartupInfo.hStdInput = inherited[0];
                startup.StartupInfo.hStdOutput = inherited[1];
                startup.StartupInfo.hStdError = inherited[2];
                startup.lpAttributeList = attributes;
                PROCESS_INFORMATION information;
                var command = (commandLine + "\0").ToCharArray();
                var environmentText = block.ToString();
                bool created;
                fixed (char* commandPointer = command) fixed (char* environmentPointer = environmentText) fixed (char* application = executable)
                {
                    created = PInvoke.CreateProcess(application, new PWSTR(commandPointer), null, null, true,
                        PROCESS_CREATION_FLAGS.CREATE_NO_WINDOW | PROCESS_CREATION_FLAGS.EXTENDED_STARTUPINFO_PRESENT | PROCESS_CREATION_FLAGS.CREATE_UNICODE_ENVIRONMENT,
                        environmentPointer, null, (STARTUPINFOW*)&startup, &information);
                }
                if (!created)
                {
                    var code = Marshal.GetLastPInvokeError();
                    throw new NativeProcessException(new Win32Exception(code).Message, code);
                }
                PInvoke.CloseHandle(information.hThread);
                var owned = new NativeOwnedProcess(jobHandle, new SafeFileHandle(information.hProcess, ownsHandle: true), (int)information.dwProcessId,
                    new FileStream(inWrite, FileAccess.Write, 1), new FileStream(outRead, FileAccess.Read, 1), new FileStream(errRead, FileAccess.Read, 1));
                inWrite = outRead = errRead = null;
                return owned;
            }
            finally
            {
                PInvoke.DeleteProcThreadAttributeList(attributes);
                NativeMemory.Free(attributes);
            }
        }
        catch
        {
            jobHandle.Dispose();
            throw;
        }
        finally
        {
            // The child's ends belong to the child now; ours close here.
            inRead?.Dispose(); outWrite?.Dispose(); errWrite?.Dispose();
            inWrite?.Dispose(); outRead?.Dispose(); errRead?.Dispose();
        }
    }

    /// <summary>True when processId belongs to this process's job (its descendants, e.g. askpass helpers).</summary>
    public bool Contains(int processId)
    {
        using var other = PInvoke.OpenProcess_SafeHandle(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)processId);
        if (other.IsInvalid) return false;
        return PInvoke.IsProcessInJob(other, job, out var inJob) && inJob;
    }

    /// <summary>Ends the whole process tree now.</summary>
    public void Kill()
    {
        if (!disposed) PInvoke.TerminateJobObject(job, 1);
    }

    /// <summary>Kills the tree (closing the job does too) and releases the handles.</summary>
    public void Dispose()
    {
        if (disposed) return;
        Kill();
        disposed = true;
        exitWait.Unregister(null);
        Input.Dispose();
        Output.Dispose();
        Error.Dispose();
        job.Dispose();
        processEvent.Dispose();
        process.Dispose();
        exited.TrySetResult(-1);
    }
}
