// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.System.Ole;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.Shell.Common;

namespace TidyVNC.Native.Documents;

public enum NativeFileDialogKind { OpenConnection, SaveConnection, OpenCertificate, OpenPasswordFile }

/// <summary>Labels the app supplies (localized); null keeps the system default.</summary>
public sealed record NativeFileDialogText(string? Title = null, string? OkLabel = null, string? TidyVncFiles = null, string? TigerVncFiles = null,
                                          string? CertificateFiles = null, string? AllFiles = null);

/// <summary>
/// The Common Item Dialog (IFileOpenDialog / IFileSaveDialog), owned by the
/// requesting window (SERVICES.md section 4): plain file-system paths, an OK
/// label (Review for opening a connection file), overwrite prompts, the
/// .tidyvnc default extension and file-type filters. Show runs a modal loop
/// on the UI thread, so core delivery continues inside it and must be
/// reentrancy-safe. <see cref="CancelActive"/> closes an open dialog as
/// cancelled, for exit and session end. UI (STA) thread only.
/// </summary>
public static unsafe class NativeFileDialogs
{
    private static readonly Guid FileOpenDialogClass = new("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7");
    private static readonly Guid FileSaveDialogClass = new("C0B4E2F3-BA21-4773-8DBA-335EC946EB8B");
    private const int Cancelled = unchecked((int)0x800704C7); // HRESULT_FROM_WIN32(ERROR_CANCELLED)

    private static IFileDialog* active;

    public static bool IsOpen => active is not null;

    /// <summary>Closes the open dialog, if any, as if the user cancelled it.</summary>
    public static void CancelActive()
    {
        if (active is null) return;
        // Close alone is honoured only from dialog event callbacks; the Cancel
        // command posted to the dialog window works from any point in its loop.
        try { active->Close(new HRESULT(Cancelled)); }
        catch (System.Runtime.InteropServices.COMException) { }
        var iid = typeof(IOleWindow).GUID;
        void* window;
        if (((IUnknown*)active)->QueryInterface(&iid, &window).Succeeded)
        {
            try
            {
                HWND handle;
                ((IOleWindow*)window)->GetWindow(&handle);
                PInvoke.PostMessage(handle, 0x0111, new WPARAM(2), default); // WM_COMMAND, IDCANCEL
            }
            catch (System.Runtime.InteropServices.COMException) { }
            finally { ((IOleWindow*)window)->Release(); }
        }
    }

    /// <summary>Shows the dialog; null when cancelled. Never shows a second dialog while one is open.</summary>
    public static string? Show(nint owner, NativeFileDialogKind kind, NativeFileDialogText text, string? initialFolder = null, string? fileName = null)
    {
        if (active is not null) throw new InvalidOperationException("A file dialog is already open");
        var save = kind == NativeFileDialogKind.SaveConnection;
        var clsid = save ? FileSaveDialogClass : FileOpenDialogClass;
        var iid = typeof(IFileDialog).GUID;
        void* instance;
        PInvoke.CoCreateInstance(&clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iid, &instance).ThrowOnFailure();
        var dialog = (IFileDialog*)instance;
        try
        {
            FILEOPENDIALOGOPTIONS options;
            dialog->GetOptions(&options);
            options |= FILEOPENDIALOGOPTIONS.FOS_FORCEFILESYSTEM | FILEOPENDIALOGOPTIONS.FOS_PATHMUSTEXIST | FILEOPENDIALOGOPTIONS.FOS_NOCHANGEDIR;
            options |= save ? FILEOPENDIALOGOPTIONS.FOS_OVERWRITEPROMPT | FILEOPENDIALOGOPTIONS.FOS_STRICTFILETYPES : FILEOPENDIALOGOPTIONS.FOS_FILEMUSTEXIST;
            dialog->SetOptions(options);

            var filters = kind switch
            {
                NativeFileDialogKind.OpenConnection => new[]
                {
                    (text.TidyVncFiles ?? "TidyVNC connection", "*.tidyvnc"), (text.TigerVncFiles ?? "TigerVNC connection", "*.tigervnc"),
                    (text.AllFiles ?? "All files", "*.*"),
                },
                NativeFileDialogKind.SaveConnection => [(text.TidyVncFiles ?? "TidyVNC connection", "*.tidyvnc")],
                NativeFileDialogKind.OpenCertificate => [(text.CertificateFiles ?? "Certificates", "*.pem;*.crt;*.cer;*.crl"), (text.AllFiles ?? "All files", "*.*")],
                _ => [(text.AllFiles ?? "All files", "*.*")],
            };
            var pinned = new List<System.Runtime.InteropServices.GCHandle>();
            try
            {
                var specs = new COMDLG_FILTERSPEC[filters.Length];
                for (var i = 0; i < filters.Length; i++)
                {
                    var name = System.Runtime.InteropServices.GCHandle.Alloc((filters[i].Item1 + "\0").ToCharArray(), System.Runtime.InteropServices.GCHandleType.Pinned);
                    var spec = System.Runtime.InteropServices.GCHandle.Alloc((filters[i].Item2 + "\0").ToCharArray(), System.Runtime.InteropServices.GCHandleType.Pinned);
                    pinned.Add(name);
                    pinned.Add(spec);
                    specs[i] = new COMDLG_FILTERSPEC { pszName = (char*)name.AddrOfPinnedObject(), pszSpec = (char*)spec.AddrOfPinnedObject() };
                }
                fixed (COMDLG_FILTERSPEC* list = specs) dialog->SetFileTypes((uint)specs.Length, list);
            }
            finally
            {
                foreach (var handle in pinned) handle.Free();
            }
            if (save) fixed (char* extension = "tidyvnc") dialog->SetDefaultExtension(extension);
            if (text.Title is { } title) fixed (char* value = title) dialog->SetTitle(value);
            if (text.OkLabel is { } label) fixed (char* value = label) dialog->SetOkButtonLabel(value);
            if (fileName is { } name2) fixed (char* value = name2) dialog->SetFileName(value);
            if (initialFolder is { } folder && Path.IsPathFullyQualified(folder))
            {
                var itemIid = typeof(IShellItem).GUID;
                void* item;
                fixed (char* value = folder)
                {
                    if (PInvoke.SHCreateItemFromParsingName(value, null, &itemIid, &item).Succeeded)
                    {
                        dialog->SetFolder((IShellItem*)item);
                        ((IShellItem*)item)->Release();
                    }
                }
            }

            active = dialog;
            try { dialog->Show(new HWND(owner)); }
            catch (System.Runtime.InteropServices.COMException error) when (error.HResult == Cancelled) { return null; }
            finally { active = null; }

            IShellItem* result;
            dialog->GetResult(&result);
            try
            {
                PWSTR path;
                result->GetDisplayName(SIGDN.SIGDN_FILESYSPATH, &path);
                try { return path.ToString(); }
                finally { PInvoke.CoTaskMemFree(path.Value); }
            }
            finally
            {
                result->Release();
            }
        }
        finally
        {
            dialog->Release();
        }
    }
}
