// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.System.Com.StructuredStorage;
using Windows.Win32.System.Variant;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.Shell.Common;
using Windows.Win32.UI.Shell.PropertiesSystem;

namespace TidyVNC.Native.Activation;

/// <summary>A Jump List task: a shell launch of the app with fixed, non-secret arguments.</summary>
public sealed record NativeJumpListTask(string Title, string Arguments);

/// <summary>
/// The taskbar Jump List for an unpackaged app (SERVICES.md section 12):
/// ICustomDestinationList tasks for the process's AppUserModelID. Tasks are
/// ordinary shell launches, so they reach the primary instance by
/// redirection. The WinRT JumpList needs package identity; this does not.
/// Call on a COM-initialized thread (the UI thread).
/// </summary>
public static unsafe class NativeJumpList
{
    private static readonly Guid DestinationListClass = new("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
    private static readonly Guid ObjectCollectionClass = new("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");
    private static readonly Guid ShellLinkClass = new("00021401-0000-0000-C000-000000000046");
    private static readonly PROPERTYKEY Title = new() { fmtid = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), pid = 2 };
    private const ushort WideString = 31; // VT_LPWSTR

    private static T* Create<T>(Guid clsid) where T : unmanaged
    {
        var iid = typeof(T).GUID;
        void* instance;
        PInvoke.CoCreateInstance(&clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iid, &instance).ThrowOnFailure();
        return (T*)instance;
    }

    private static T* Query<T>(IUnknown* source) where T : unmanaged
    {
        var iid = typeof(T).GUID;
        void* result;
        source->QueryInterface(&iid, &result).ThrowOnFailure();
        return (T*)result;
    }

    /// <summary>Replaces the Jump List tasks for appId; tasks launch executable with their arguments.</summary>
    public static void Publish(string appId, string executable, IReadOnlyList<NativeJumpListTask> tasks)
    {
        if (!Path.IsPathFullyQualified(executable)) throw new ArgumentException("The executable needs a full path", nameof(executable));
        var list = Create<ICustomDestinationList>(DestinationListClass);
        var collection = Create<IObjectCollection>(ObjectCollectionClass);
        try
        {
            fixed (char* id = appId) list->SetAppID(id);
            var removedIid = typeof(IObjectArray).GUID;
            uint slots;
            void* removed;
            list->BeginList(&slots, &removedIid, &removed);
            ((IUnknown*)removed)->Release();
            foreach (var task in tasks)
            {
                var link = Create<IShellLinkW>(ShellLinkClass);
                try
                {
                    fixed (char* path = executable) link->SetPath(path);
                    fixed (char* arguments = task.Arguments) link->SetArguments(arguments);
                    fixed (char* icon = executable) link->SetIconLocation(icon, 0);
                    var store = Query<IPropertyStore>((IUnknown*)link);
                    try
                    {
                        var value = new PROPVARIANT();
                        value.Anonymous.Anonymous.vt = (VARENUM)WideString;
                        value.Anonymous.Anonymous.Anonymous.pwszVal = new PWSTR((char*)Marshal.StringToCoTaskMemUni(task.Title));
                        try
                        {
                            var key = Title;
                            store->SetValue(&key, &value);
                            store->Commit();
                        }
                        finally { PInvoke.PropVariantClear(&value); }
                    }
                    finally { store->Release(); }
                    collection->AddObject((IUnknown*)link);
                }
                finally { link->Release(); }
            }
            if (tasks.Count > 0)
            {
                var array = Query<IObjectArray>((IUnknown*)collection);
                try { list->AddUserTasks(array); }
                finally { array->Release(); }
            }
            list->CommitList();
        }
        finally
        {
            collection->Release();
            list->Release();
        }
    }

    /// <summary>Removes the Jump List for appId.</summary>
    public static void Delete(string appId)
    {
        var list = Create<ICustomDestinationList>(DestinationListClass);
        try { fixed (char* id = appId) list->DeleteList(id); }
        finally { list->Release(); }
    }
}
