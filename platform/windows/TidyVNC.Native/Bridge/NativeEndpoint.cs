// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeEndpointIssue : uint
{
    Required = 0, TooLong, InvalidHost, UnmatchedBracket, InvalidPort, InvalidPath, InvalidRoute, UnsupportedTransport,
    InvalidText, Unavailable,
}

/// <summary>Shared viewer address syntax (NativeEndpoint.swift). No DNS, file or network IO.</summary>
public static class NativeEndpoint
{
    public static unsafe void Validate(string address, bool allowUnixSockets = true)
    {
        var bytes = NativeText.Utf8(address);
        if (bytes.Length > 4097) bytes = bytes[..4097];
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes)
            Abi.Check(NativeMethods.tidyvnc_endpoint_validate(NativeText.Span(p, bytes.Length), allowUnixSockets ? 1u : 0u, &error), &error);
    }

    /// <summary>The problem with an address, or null when valid. Blank requires entry (Connect is disabled).</summary>
    public static NativeEndpointIssue? Issue(string address, bool allowUnixSockets = true)
    {
        if (address.Length == 0) return NativeEndpointIssue.Required;
        try { Validate(address, allowUnixSockets); return null; }
        catch (NativeError error)
        {
            if (error.Domain == Tidyvnc.TIDYVNC_DOMAIN_ENDPOINT && error.Detail is >= 1 and <= 7) return (NativeEndpointIssue)error.Detail;
            return error.Status == NativeStatus.InvalidArgument ? NativeEndpointIssue.InvalidText : NativeEndpointIssue.Unavailable;
        }
    }

    /// <summary>Strict decimal port 0..65535.</summary>
    public static unsafe uint? ParsePort(string text)
    {
        var bytes = NativeText.Utf8(text);
        if (bytes.Length > 16) return null;
        uint port = 0;
        fixed (byte* p = bytes)
            return NativeMethods.tidyvnc_port_parse(NativeText.Span(p, bytes.Length), &port, null) == Tidyvnc.TIDYVNC_OK ? port : null;
    }
}

/// <summary>A parsed endpoint with an optional route identity (tidyvnc_endpoint_create).</summary>
public sealed class NativeEndpointIdentity : IDisposable
{
    internal NativeHandle Handle { get; }
    internal ulong Raw => Handle.Raw;
    public NativeEndpointKind Kind { get; }
    public uint Port { get; }
    public string Host { get; }
    public string Scope { get; }
    public string Path { get; }
    public string Route { get; }

    public enum NativeEndpointKind : uint { Tcp = 1, Unix = 2 }

    private unsafe NativeEndpointIdentity(NativeHandle handle)
    {
        Handle = handle;
        var info = Abi.Init<tidyvnc_endpoint_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_endpoint_get(handle.Raw, &info, &error), &error);
        Kind = (NativeEndpointKind)info.transport; Port = info.port;
        Host = NativeText.Decode(info.host); Scope = NativeText.Decode(info.scope);
        Path = NativeText.Decode(info.path); Route = NativeText.Decode(info.route);
    }

    public static unsafe NativeEndpointIdentity Create(string endpoint, string route = "", bool allowUnixSockets = false)
    {
        var e = NativeText.Utf8(endpoint);
        var r = NativeText.Utf8(route);
        var error = Abi.Init<tidyvnc_error>();
        ulong raw = 0;
        fixed (byte* ep = e) fixed (byte* rp = r)
            Abi.Check(NativeMethods.tidyvnc_endpoint_create(NativeText.Span(ep, e.Length), NativeText.Span(rp, r.Length),
                allowUnixSockets ? 1u : 0u, &raw, &error), &error);
        return new NativeEndpointIdentity(NativeHandle.Adopt(raw));
    }

    public void Dispose() => Handle.Dispose();
}

/// <summary>
/// Platform-independent meaning of a native error code (tidyvnc_native_error_category,
/// CORE.md section 4). Codes are Winsock/Win32 values on Windows.
/// </summary>
public enum NativeErrorCategory : uint { Other = 0, NetworkPolicy = 1, Refused = 2, Routing = 3, TimedOut = 4 }

public static class NativeErrorCategories
{
    public static unsafe NativeErrorCategory Classify(int nativeError)
    {
        uint category = 0;
        return NativeMethods.tidyvnc_native_error_category(nativeError, &category, null) == Tidyvnc.TIDYVNC_OK &&
               Enum.IsDefined((NativeErrorCategory)category)
            ? (NativeErrorCategory)category : NativeErrorCategory.Other;
    }
}
