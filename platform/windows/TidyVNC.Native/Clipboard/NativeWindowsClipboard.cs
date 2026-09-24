// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TidyVNC.Native.Clipboard;

public enum NativeClipboardAccessError { Changed, TooLarge, InvalidText, Unavailable, WriteFailed, Closed }

public sealed class NativeClipboardAccessException(NativeClipboardAccessError error) : Exception($"Clipboard {error}")
{
    public NativeClipboardAccessError Error { get; } = error;
}

public enum NativeClipboardContentKind { Text, Remote, Unavailable }

public sealed record NativeClipboardContent(NativeClipboardContentKind Kind, string? Text = null)
{
    public override string ToString() => $"NativeClipboardContent({Kind})";
}

/// <summary>
/// The host clipboard contract the coordinator uses (NativePasteboardAccess on
/// macOS), also implemented by deterministic test adapters. Change numbers are
/// the system clipboard sequence numbers.
/// </summary>
public interface INativeClipboardAccess
{
    /// <summary>Raised (on any thread) when the clipboard changes.</summary>
    event Action? Changed;
    Task<uint> CurrentChangeAsync();
    Task<NativeClipboardContent> ReadAsync(uint expectedChange, int maximumBytes);
    /// <summary>Writes remote text with the provenance and no-cloud-upload markers; returns the new change.</summary>
    Task<uint> WriteRemoteAsync(string text, ulong session, ulong generation, int maximumBytes);
    /// <summary>Writes app-originated local text without provenance (e.g. copied diagnostics).</summary>
    Task<uint> WriteLocalAsync(string text, int maximumBytes);
}

/// <summary>
/// The Windows clipboard (SERVICES.md section 6, D21), owned by one worker
/// thread with a message-only window: AddClipboardFormatListener replaces
/// polling, and every OpenClipboard (which fails while another program holds
/// the clipboard) is retried briefly off the UI thread, then reported as
/// Unavailable. Text only (CF_UNICODETEXT). Remote-origin writes also carry
/// the private TidyVNC.RemoteOrigin format (process, session, generation) and
/// CanUploadToCloudClipboard = 0 in the same transaction; a write that cannot
/// include both markers is removed again and reported, never left unmarked.
/// </summary>
public sealed unsafe class NativeWindowsClipboard : INativeClipboardAccess, IDisposable
{
    public const string RemoteOriginFormat = "TidyVNC.RemoteOrigin";
    public const string CloudUploadFormat = "CanUploadToCloudClipboard";
    private const uint UnicodeText = 13; // CF_UNICODETEXT
    private const uint WorkMessage = 0x8001; // WM_APP + 1
    private const uint ClipboardUpdate = 0x031D; // WM_CLIPBOARDUPDATE
    private const int OpenAttempts = 10;

    private static NativeWindowsClipboard? instance;
    private readonly Thread thread;
    private readonly BlockingCollection<Action> work = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly uint originFormat, cloudFormat;
    private HWND window;
    private bool closed;

    public event Action? Changed;

    public NativeWindowsClipboard()
    {
        if (Interlocked.CompareExchange(ref instance, this, null) is not null)
            throw new InvalidOperationException("One clipboard owner per process");
        fixed (char* origin = RemoteOriginFormat) originFormat = PInvoke.RegisterClipboardFormat(origin);
        fixed (char* cloud = CloudUploadFormat) cloudFormat = PInvoke.RegisterClipboardFormat(cloud);
        thread = new Thread(Run) { IsBackground = true, Name = "TidyVNC clipboard" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Task.GetAwaiter().GetResult();
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static LRESULT WindowProcedure(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        var owner = instance;
        if (owner is not null && hwnd == owner.window)
        {
            if (message == WorkMessage)
            {
                while (owner.work.TryTake(out var action)) action();
                return new LRESULT(0);
            }
            if (message == ClipboardUpdate)
            {
                try { owner.Changed?.Invoke(); } catch (Exception error) { System.Diagnostics.Trace.TraceError($"Clipboard listener failed: {error.GetType().Name}"); }
                return new LRESULT(0);
            }
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void Run()
    {
        try
        {
            var name = "TidyVNC.Clipboard." + Environment.ProcessId;
            fixed (char* className = name)
            {
                var windowClass = new WNDCLASSEXW
                {
                    cbSize = (uint)sizeof(WNDCLASSEXW),
                    lpfnWndProc = &WindowProcedure,
                    lpszClassName = className,
                };
                if (PInvoke.RegisterClassEx(&windowClass) == 0) throw new InvalidOperationException("Clipboard window class");
                window = PInvoke.CreateWindowEx(0, name, null, 0, 0, 0, 0, 0, new HWND(-3), null, null, null); // HWND_MESSAGE
                if (window.IsNull) throw new InvalidOperationException("Clipboard window");
                if (!PInvoke.AddClipboardFormatListener(window)) throw new InvalidOperationException("Clipboard listener");
            }
            ready.SetResult();
        }
        catch (Exception error)
        {
            ready.SetException(error);
            return;
        }
        MSG message;
        while (PInvoke.GetMessage(&message, HWND.Null, 0, 0) > 0)
        {
            PInvoke.TranslateMessage(&message);
            PInvoke.DispatchMessage(&message);
        }
    }

    private Task<T> Perform<T>(Func<T> body)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (closed) { result.SetException(new NativeClipboardAccessException(NativeClipboardAccessError.Closed)); return result.Task; }
        work.Add(() =>
        {
            try { result.SetResult(body()); }
            catch (Exception error) { result.SetException(error); }
        });
        if (!PInvoke.PostMessage(window, WorkMessage, default, default))
            while (work.TryTake(out var pending)) pending();
        return result.Task;
    }

    /// <summary>OpenClipboard with a short backoff; Unavailable when another program keeps it.</summary>
    private void Open()
    {
        for (var attempt = 1; ; attempt++)
        {
            if (PInvoke.OpenClipboard(window)) return;
            if (attempt >= OpenAttempts) throw new NativeClipboardAccessException(NativeClipboardAccessError.Unavailable);
            Thread.Sleep(5 * attempt);
        }
    }

    public Task<uint> CurrentChangeAsync() => Perform(() => PInvoke.GetClipboardSequenceNumber());

    private static void Validate(string text, int maximumBytes)
    {
        if (maximumBytes is <= 0 or > 16 * 1024 * 1024) throw new NativeClipboardAccessException(NativeClipboardAccessError.TooLarge);
        if (text.Contains('\0', StringComparison.Ordinal)) throw new NativeClipboardAccessException(NativeClipboardAccessError.InvalidText);
        int bytes;
        try { bytes = new UTF8Encoding(false, true).GetByteCount(text); }
        catch (EncoderFallbackException) { throw new NativeClipboardAccessException(NativeClipboardAccessError.InvalidText); }
        if (bytes > maximumBytes) throw new NativeClipboardAccessException(NativeClipboardAccessError.TooLarge);
    }

    public Task<NativeClipboardContent> ReadAsync(uint expectedChange, int maximumBytes) => Perform(() =>
    {
        if (PInvoke.GetClipboardSequenceNumber() != expectedChange) throw new NativeClipboardAccessException(NativeClipboardAccessError.Changed);
        Open();
        NativeClipboardContent content;
        try
        {
            if (PInvoke.GetClipboardSequenceNumber() != expectedChange) throw new NativeClipboardAccessException(NativeClipboardAccessError.Changed);
            if (OwnOrigin()) content = new(NativeClipboardContentKind.Remote);
            else if (!PInvoke.IsClipboardFormatAvailable(UnicodeText)) content = new(NativeClipboardContentKind.Unavailable);
            else content = new(NativeClipboardContentKind.Text, ReadText(maximumBytes));
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
        if (PInvoke.GetClipboardSequenceNumber() != expectedChange) throw new NativeClipboardAccessException(NativeClipboardAccessError.Changed);
        return content;
    });

    /// <summary>A marker written by this process: its text came from a remote desktop and is not sent back.</summary>
    private bool OwnOrigin()
    {
        if (!PInvoke.IsClipboardFormatAvailable(originFormat)) return false;
        var data = PInvoke.GetClipboardData(originFormat);
        if (data.IsNull) return false;
        var memory = new HGLOBAL(data.Value);
        if (PInvoke.GlobalSize(memory) < 24) return false;
        var bytes = (byte*)PInvoke.GlobalLock(memory);
        if (bytes is null) return false;
        try { return BitConverter.ToUInt64(new ReadOnlySpan<byte>(bytes, 8)) == (ulong)Environment.ProcessId; }
        finally { PInvoke.GlobalUnlock(memory); }
    }

    private static string ReadText(int maximumBytes)
    {
        var data = PInvoke.GetClipboardData(UnicodeText);
        if (data.IsNull) throw new NativeClipboardAccessException(NativeClipboardAccessError.Unavailable);
        var memory = new HGLOBAL(data.Value);
        var size = (long)(nuint)PInvoke.GlobalSize(memory);
        // UTF-16 never needs more than 2 bytes per UTF-8 byte of the limit (plus a terminator).
        var capacity = (int)Math.Min(size / 2, (long)maximumBytes + 1);
        var chars = (char*)PInvoke.GlobalLock(memory);
        if (chars is null) throw new NativeClipboardAccessException(NativeClipboardAccessError.Unavailable);
        try
        {
            var span = new ReadOnlySpan<char>(chars, capacity);
            var end = span.IndexOf('\0');
            if (end < 0)
            {
                if (size / 2 > maximumBytes) throw new NativeClipboardAccessException(NativeClipboardAccessError.TooLarge);
                throw new NativeClipboardAccessException(NativeClipboardAccessError.InvalidText);
            }
            var text = new string(span[..end]);
            Validate(text, maximumBytes);
            return text;
        }
        finally
        {
            PInvoke.GlobalUnlock(memory);
        }
    }

    private static HGLOBAL Allocate(ReadOnlySpan<byte> bytes)
    {
        var memory = PInvoke.GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, (nuint)bytes.Length);
        if (memory.IsNull) throw new NativeClipboardAccessException(NativeClipboardAccessError.WriteFailed);
        var target = PInvoke.GlobalLock(memory);
        if (target is null)
        {
            PInvoke.GlobalFree(memory);
            throw new NativeClipboardAccessException(NativeClipboardAccessError.WriteFailed);
        }
        bytes.CopyTo(new Span<byte>(target, bytes.Length));
        PInvoke.GlobalUnlock(memory);
        return memory;
    }

    /// <summary>SetClipboardData takes ownership only on success.</summary>
    private static bool Set(uint format, ReadOnlySpan<byte> bytes)
    {
        var memory = Allocate(bytes);
        if (!PInvoke.SetClipboardData(format, new HANDLE(memory.Value)).IsNull) return true;
        PInvoke.GlobalFree(memory);
        return false;
    }

    private uint Write(string text, int maximumBytes, ReadOnlySpan<byte> origin)
    {
        Validate(text, maximumBytes);
        var unicode = new byte[(text.Length + 1) * 2];
        MemoryMarshal.AsBytes(text.AsSpan()).CopyTo(unicode);
        Open();
        try
        {
            if (!PInvoke.EmptyClipboard()) throw new NativeClipboardAccessException(NativeClipboardAccessError.WriteFailed);
            var written = Set(UnicodeText, unicode);
            if (written && !origin.IsEmpty)
            {
                Span<byte> zero = stackalloc byte[4];
                zero.Clear();
                written = Set(originFormat, origin) && Set(cloudFormat, zero);
            }
            if (!written)
            {
                // Never leave remote text on the clipboard without its markers.
                PInvoke.EmptyClipboard();
                throw new NativeClipboardAccessException(NativeClipboardAccessError.WriteFailed);
            }
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
        return PInvoke.GetClipboardSequenceNumber();
    }

    public Task<uint> WriteRemoteAsync(string text, ulong session, ulong generation, int maximumBytes) => Perform(() =>
    {
        Span<byte> origin = stackalloc byte[24];
        BitConverter.TryWriteBytes(origin, (ulong)Environment.ProcessId);
        BitConverter.TryWriteBytes(origin[8..], session);
        BitConverter.TryWriteBytes(origin[16..], generation);
        return Write(text, maximumBytes, origin.ToArray());
    });

    public Task<uint> WriteLocalAsync(string text, int maximumBytes) => Perform(() => Write(text, maximumBytes, []));

    public void Dispose()
    {
        if (closed) return;
        closed = true;
        var finished = new ManualResetEventSlim();
        work.Add(() =>
        {
            PInvoke.RemoveClipboardFormatListener(window);
            PInvoke.DestroyWindow(window);
            PInvoke.PostQuitMessage(0);
            finished.Set();
        });
        if (PInvoke.PostMessage(window, WorkMessage, default, default)) finished.Wait(TimeSpan.FromSeconds(5));
        thread.Join(TimeSpan.FromSeconds(5));
        work.Dispose();
        finished.Dispose();
        Interlocked.CompareExchange(ref instance, null, this);
    }
}
