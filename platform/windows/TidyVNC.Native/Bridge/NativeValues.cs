// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Security.Cryptography;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeSessionState : uint
{
    Idle = 0, Resolving, Connecting, Negotiating, Authenticating, Connected, Disconnecting, Closed, Failed,
}

public enum NativeEndReason : uint
{
    None = 0, Cancelled, PeerClosed, PromptTimeout, AuthenticationRejected, Transport, ProtocolFailure,
    Resource, InternalFailure, EventOverflow, Resolution, Connection, ResolutionTimeout, ConnectionTimeout,
    UnsupportedEndpoint, InvalidEndpoint,
}

/// <summary>One published session state (NativeValues.swift NativeSnapshot).</summary>
public sealed record NativeSnapshot(
    NativeSessionState State, NativeEndReason EndReason, int NativeCode, uint Width, uint Height,
    bool SupportsResize, bool ResizePending, ulong Generation, ulong Frames, ulong Bells,
    NativeConnectionInformation? Information = null)
{
    internal static NativeSnapshot From(in tidyvnc_snapshot value, NativeSessionState? stateOverride = null,
                                        NativeConnectionInformation? information = null)
        => new(stateOverride ?? (Enum.IsDefined((NativeSessionState)value.state) ? (NativeSessionState)value.state : NativeSessionState.Failed),
               Enum.IsDefined((NativeEndReason)value.end_reason) ? (NativeEndReason)value.end_reason : NativeEndReason.InternalFailure,
               value.native_error, value.width, value.height, value.supports_resize != 0, value.resize_pending != 0,
               value.generation, value.frames, value.bells, information);
}

/// <summary>Negotiated connection details (NativeConnectionInformation in Swift).</summary>
public sealed record NativeConnectionInformation(
    ulong Generation, ulong Frames, ulong BitsPerSecond, uint Width, uint Height, uint ProtocolMajor, uint ProtocolMinor,
    uint SecurityType, bool CredentialsSecure, bool NameTruncated, int RequestedEncoding, int LastEncoding,
    string DesktopName, string PixelFormat, string SecurityName, string RequestedEncodingName, string LastEncodingName)
{
    internal static unsafe NativeConnectionInformation From(tidyvnc_connection_info value)
        => new(value.snapshot.generation, value.snapshot.frames, value.bits_per_second, value.snapshot.width, value.snapshot.height,
               value.protocol_major, value.protocol_minor, value.security_type, value.credentials_secure != 0, value.name_truncated != 0,
               value.requested_encoding, value.last_encoding,
               NativeText.Fixed(value.desktop_name, 1025), NativeText.Fixed(value.pixel_format, 128),
               NativeText.Fixed(value.security_name, 64), NativeText.Fixed(value.requested_encoding_name, 32),
               NativeText.Fixed(value.last_encoding_name, 32));

    /// <summary>Diagnostics safe to copy: no remote names, endpoints, paths or authentication data.</summary>
    public string RedactedDiagnostics =>
        $"""
        TidyVNC connection diagnostics
        Protocol: RFB {ProtocolMajor}.{ProtocolMinor}
        Security: {SecurityName} ({SecurityType})
        Desktop size: {Width} × {Height}
        Pixel format: {PixelFormat}
        Requested encoding: {RequestedEncodingName}
        Last used encoding: {(LastEncoding < 0 ? "Not received" : LastEncodingName)}
        Line speed estimate: {(Frames == 0 ? "Not sampled" : $"{BitsPerSecond / 1000} kbit/s")}
        Frames received: {Frames}
        Endpoint and desktop name omitted.
        """;
}

public readonly record struct NativeOperation(ulong Id, ulong Generation);

public sealed record NativeCompletion(NativeOperation Operation, NativeSnapshot Snapshot);

/// <summary>A command the core admitted but did not complete successfully.</summary>
public sealed class NativeCommandFailure : Exception
{
    public enum ResultKind : uint { Succeeded = 0, Cancelled, Failed }
    public enum FailureReason : uint { None = 0, TimedOut, ServerRejected }

    public NativeOperation Operation { get; }
    public ResultKind Result { get; }
    public FailureReason Reason { get; }
    public uint NativeResult { get; }
    public NativeSnapshot Snapshot { get; }

    internal NativeCommandFailure(NativeOperation operation, ResultKind result, FailureReason reason, uint nativeResult, NativeSnapshot snapshot)
        : base($"Operation {result} ({reason})")
    {
        Operation = operation; Result = result; Reason = reason; NativeResult = nativeResult; Snapshot = snapshot;
    }
}

public readonly record struct NativePixelRect(uint X, uint Y, uint Width, uint Height);

/// <summary>
/// A retained, immutable frame or cursor lease (NativeImage in Swift). Pixels
/// stay in the core; renderers borrow them through the lease while it lives.
/// </summary>
public sealed class NativeImage : IDisposable
{
    public enum PixelFormat : uint { Bgra8 = 1, Rgba8 = 2 }
    public enum AlphaMode : uint { Opaque = 1, Straight = 2, Premultiplied = 3 }

    internal NativeHandle Handle { get; }
    public uint Width { get; }
    public uint Height { get; }
    public ulong Stride { get; }
    public ulong Generation { get; }
    public ulong SizeGeneration { get; }
    public ulong Sequence { get; }
    public ulong PreviousSequence { get; }
    public NativePixelRect Damage { get; }
    public Guid StreamId { get; }
    public uint HotspotX { get; }
    public uint HotspotY { get; }
    public PixelFormat Format { get; }
    public AlphaMode Alpha { get; }

    internal unsafe NativeImage(NativeHandle owner, ulong previousSequence = 0, NativePixelRect? damage = null, Guid? streamId = null)
    {
        var info = Abi.Init<tidyvnc_image_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_image_get(owner.Raw, &info, &error), &error);
        if (!Enum.IsDefined((PixelFormat)info.format) || !Enum.IsDefined((AlphaMode)info.alpha) ||
            info.origin != Tidyvnc.TIDYVNC_ORIGIN_TOP_LEFT)
            throw new NativeError(NativeStatus.Unsupported, "Unsupported image format");
        Handle = owner; Width = info.width; Height = info.height; Stride = info.stride;
        Generation = info.generation; SizeGeneration = info.size_generation; Sequence = info.sequence;
        HotspotX = info.hotspot_x; HotspotY = info.hotspot_y;
        Format = (PixelFormat)info.format; Alpha = (AlphaMode)info.alpha;
        PreviousSequence = previousSequence; StreamId = streamId ?? Guid.NewGuid();
        Damage = damage ?? new NativePixelRect(0, 0, info.width, info.height);
    }

    /// <summary>Borrowed pixels, valid while this lease is alive. Callers keep the lease referenced.</summary>
    public unsafe ReadOnlySpan<byte> BorrowPixels()
    {
        var info = Abi.Init<tidyvnc_image_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_image_get(Handle.Raw, &info, &error), &error);
        if (info.pixels.data == null || info.pixels.length > int.MaxValue)
            throw new NativeError(NativeStatus.InternalFailure, "Invalid image storage");
        return new ReadOnlySpan<byte>(info.pixels.data, (int)info.pixels.length);
    }

    public byte[] CopyPixels() => BorrowPixels().ToArray();

    private NativeImage(NativeImage source, NativeHandle handle)
    {
        Handle = handle; Width = source.Width; Height = source.Height; Stride = source.Stride;
        Generation = source.Generation; SizeGeneration = source.SizeGeneration; Sequence = source.Sequence;
        PreviousSequence = source.PreviousSequence; Damage = source.Damage; StreamId = source.StreamId;
        HotspotX = source.HotspotX; HotspotY = source.HotspotY; Format = source.Format; Alpha = source.Alpha;
    }

    /// <summary>
    /// An independent reference to the same lease. Each holder (session state,
    /// a render worker) disposes its own, so pixels are freed deterministically.
    /// </summary>
    public NativeImage Clone() => new(this, NativeHandle.Retain(Handle.Raw));

    public void Dispose() => Handle.Dispose();
}

/// <summary>An authentication or trust request (NativePrompt in Swift).</summary>
public sealed record NativePrompt(
    ulong Id, ulong Generation, NativePrompt.PromptKind Kind, bool Secure, uint SecurityType, bool UsernameRequired,
    uint CertificateStatus, string ServerName, string Fingerprint, byte[] Identity)
{
    public enum PromptKind : uint { Credentials = 1, Certificate = 2, HostKey = 3 }

    internal static unsafe NativePrompt Adopt(ulong raw)
    {
        using var owner = NativeHandle.Adopt(raw);
        var info = Abi.Init<tidyvnc_prompt_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_prompt_get(owner.Raw, &info, &error), &error);
        uint securityType = 0;
        Abi.Check(NativeMethods.tidyvnc_prompt_security_type(owner.Raw, &securityType, &error), &error);
        if (!Enum.IsDefined((PromptKind)info.kind)) throw new NativeError(NativeStatus.Unsupported, "Unsupported authentication prompt");
        return new NativePrompt(info.id, info.generation, (PromptKind)info.kind, info.secure != 0, securityType,
            info.username_required != 0, info.certificate_status, NativeText.Decode(info.server_name),
            NativeText.Decode(info.fingerprint), NativeText.Copy(info.identity));
    }

    /// <summary>SHA-256 of the raw identity, upper-case hex pairs separated by colons.</summary>
    public string? Sha256Fingerprint => Identity.Length is > 0 and <= 65536
        ? string.Join(':', SHA256.HashData(Identity).Select(b => b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)))
        : null;

    public override string ToString() => $"NativePrompt({Kind}, <redacted>)";
}
