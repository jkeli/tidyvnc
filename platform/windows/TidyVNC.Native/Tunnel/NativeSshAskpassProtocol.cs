// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Buffers.Binary;
using System.Text;

namespace TidyVNC.Native.Tunnel;

/// <summary>
/// Frames between tidyvnc-ssh-askpass.exe and the app over a per-attempt
/// named pipe (SERVICES.md section 11). Shared as source by the helper, so
/// it has no dependencies. Request: "TVAP", version 1, kind, the 32-byte
/// attempt token, then length-prefixed UTF-8 fields. Response: status and a
/// length-prefixed UTF-8 answer. All lengths are bounded; answers never
/// contain NUL, CR or LF and are at most 1023 bytes (OpenSSH's readpass bound).
/// </summary>
internal static class NativeSshAskpassProtocol
{
    public const string PipeVariable = "TIDYVNC_ASKPASS_PIPE";
    public const string TokenVariable = "TIDYVNC_ASKPASS_TOKEN";
    public const int TokenBytes = 32;
    public const int MaximumField = 4096;
    public const int MaximumAnswer = 1023;
    public const int MaximumFields = 4;
    private static readonly byte[] Magic = "TVAP"u8.ToArray();
    private const byte Version = 1;

    /// <summary>A prompt (SSH_ASKPASS) or a host key observation (KnownHostsCommand).</summary>
    public enum Kind : byte { Prompt = 1, HostKey = 2 }

    public enum Status : byte { Answer = 0, Cancelled = 1 }

    public sealed record Request(Kind Kind, byte[] Token, IReadOnlyList<string> Fields);

    private static readonly UTF8Encoding Strict = new(false, true);

    public static byte[] EncodeRequest(Kind kind, ReadOnlySpan<byte> token, IReadOnlyList<string> fields)
    {
        if (token.Length != TokenBytes || fields.Count > MaximumFields) throw new ArgumentException("Invalid askpass request");
        var output = new MemoryStream();
        output.Write(Magic);
        output.WriteByte(Version);
        output.WriteByte((byte)kind);
        output.Write(token);
        output.WriteByte((byte)fields.Count);
        Span<byte> length = stackalloc byte[4];
        foreach (var field in fields)
        {
            var bytes = Strict.GetBytes(field);
            if (bytes.Length > MaximumField) throw new ArgumentException("Askpass field too long");
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)bytes.Length);
            output.Write(length);
            output.Write(bytes);
        }
        return output.ToArray();
    }

    private static void ReadExactly(Stream stream, Span<byte> buffer)
    {
        stream.ReadExactly(buffer);
    }

    /// <summary>Reads one request; throws InvalidDataException for anything malformed.</summary>
    public static Request DecodeRequest(Stream stream)
    {
        Span<byte> header = stackalloc byte[6];
        ReadExactly(stream, header);
        if (!header[..4].SequenceEqual(Magic) || header[4] != Version || header[5] is not ((byte)Kind.Prompt or (byte)Kind.HostKey))
            throw new InvalidDataException("askpass header");
        var token = new byte[TokenBytes];
        ReadExactly(stream, token);
        Span<byte> count = stackalloc byte[1];
        ReadExactly(stream, count);
        if (count[0] > MaximumFields) throw new InvalidDataException("askpass fields");
        var fields = new List<string>();
        Span<byte> length = stackalloc byte[4];
        for (var i = 0; i < count[0]; i++)
        {
            ReadExactly(stream, length);
            var n = BinaryPrimitives.ReadUInt32BigEndian(length);
            if (n > MaximumField) throw new InvalidDataException("askpass field length");
            var bytes = new byte[n];
            ReadExactly(stream, bytes);
            try { fields.Add(Strict.GetString(bytes)); }
            catch (DecoderFallbackException) { throw new InvalidDataException("askpass text"); }
        }
        return new Request((Kind)header[5], token, fields);
    }

    public static bool ValidAnswer(ReadOnlySpan<byte> answer)
        => answer.Length <= MaximumAnswer && answer.IndexOfAny((byte)0, (byte)'\r', (byte)'\n') < 0;

    public static byte[] EncodeResponse(Status status, ReadOnlySpan<byte> answer)
    {
        if (status == Status.Answer && !ValidAnswer(answer)) throw new ArgumentException("Invalid askpass answer");
        if (status == Status.Cancelled) answer = [];
        var output = new byte[5 + answer.Length];
        output[0] = (byte)status;
        BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(1), (uint)answer.Length);
        answer.CopyTo(output.AsSpan(5));
        return output;
    }

    /// <summary>The answer bytes (caller wipes them), or null when cancelled.</summary>
    public static byte[]? DecodeResponse(Stream stream)
    {
        Span<byte> header = stackalloc byte[5];
        ReadExactly(stream, header);
        var n = BinaryPrimitives.ReadUInt32BigEndian(header[1..]);
        if (header[0] > (byte)Status.Cancelled || n > MaximumAnswer) throw new InvalidDataException("askpass response");
        var answer = new byte[n];
        ReadExactly(stream, answer);
        if (header[0] == (byte)Status.Cancelled) return null;
        if (!ValidAnswer(answer)) throw new InvalidDataException("askpass answer");
        return answer;
    }
}
