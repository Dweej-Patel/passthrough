using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The pipe's frame kinds (stage 4 plan, section 4). The tray app sends 0x01 and 0x10–0x2F; the service 0x02–0x03 and
/// 0x40–0x5F; 0x1E/0x1F and 0x4E/0x4F are each side's ping and pong. A kind a side doesn't know is skipped.
/// </summary>
public static class PipeKind
{
    public const byte Hello = 0x01, Welcome = 0x02, Refused = 0x03;

    // Tray app → service.
    public const byte Reply = 0x10, Sessions = 0x11, HostState = 0x12, Output = 0x13, Replaying = 0x14, Replayed = 0x15, Ended = 0x16,
        Detached = 0x17, TranscriptChunk = 0x18, DropConn = 0x19, Admin = 0x20, TrayPing = 0x1E, TrayPong = 0x1F;

    // Service → tray app.
    public const byte Open = 0x40, Attach = 0x41, Detach = 0x42, Input = 0x43, Resize = 0x44, Close = 0x45, SetViewing = 0x46, History = 0x47,
        Transcript = 0x48, Lock = 0x49, SavePass = 0x4A, ConnClosed = 0x4B, PhoneGone = 0x4C, AdminReply = 0x50, AdminEvent = 0x51, ServicePing = 0x4E, ServicePong = 0x4F;

    /// <summary>Kinds whose payload is binary (<c>conn</c> u32, <c>session</c> as a length byte and UTF-8, then bytes); every other payload is UTF-8 JSON.</summary>
    public static bool IsBinary(byte kind) => kind is Output or Input;
}

/// <summary>One frame: a byte of kind, a big-endian u32 length, the payload (at most <see cref="MaxPayload"/>).</summary>
public readonly record struct PipeFrame(byte Kind, ReadOnlyMemory<byte> Payload)
{
    public const int MaxPayload = 1 << 20;
    public const int HeaderLength = 5;

    public byte[] Encode()
    {
        if (Payload.Length > MaxPayload) throw new ArgumentException("A pipe frame's payload is at most 1 MiB.");
        var bytes = new byte[HeaderLength + Payload.Length];
        bytes[0] = Kind;
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(1), (uint)Payload.Length);
        Payload.Span.CopyTo(bytes.AsSpan(HeaderLength));
        return bytes;
    }

    public static PipeFrame Json<T>(byte kind, T message) => new(kind, JsonSerializer.SerializeToUtf8Bytes(message, PipeJson.Options));

    public T? Read<T>() where T : class
    {
        try { return JsonSerializer.Deserialize<T>(Payload.Span, PipeJson.Options); }
        catch (JsonException) { return null; }
    }

    /// <summary>Output or input for a session on a phone's connection.</summary>
    public static PipeFrame Data(byte kind, uint conn, string session, ReadOnlySpan<byte> data)
    {
        var name = Encoding.UTF8.GetBytes(session);
        if (name.Length > 255) throw new ArgumentException("A session id is at most 255 bytes.");
        var payload = new byte[4 + 1 + name.Length + data.Length];
        BinaryPrimitives.WriteUInt32BigEndian(payload, conn);
        payload[4] = (byte)name.Length;
        name.CopyTo(payload, 5);
        data.CopyTo(payload.AsSpan(5 + name.Length));
        return new PipeFrame(kind, payload);
    }

    /// <summary>The parts of a <see cref="Data"/> frame; null when it is too short.</summary>
    public (uint Conn, string Session, ReadOnlyMemory<byte> Data)? ReadData()
    {
        var span = Payload.Span;
        if (span.Length < 5 || span.Length < 5 + span[4]) return null;
        var conn = BinaryPrimitives.ReadUInt32BigEndian(span);
        var session = Encoding.UTF8.GetString(span.Slice(5, span[4]));
        return (conn, session, Payload[(5 + span[4])..]);
    }
}

/// <summary>A frame's length was over <see cref="PipeFrame.MaxPayload"/>: the connection is closed.</summary>
public sealed class PipeFrameTooLongException() : IOException("A pipe frame was too long.");

/// <summary>Reads frames off a stream, one at a time.</summary>
public sealed class PipeFrameReader(Stream stream)
{
    private readonly byte[] _header = new byte[PipeFrame.HeaderLength];

    /// <summary>The next frame, or null at the end of the stream.</summary>
    public async Task<PipeFrame?> ReadAsync(CancellationToken cancel = default)
    {
        if (!await FillAsync(_header, cancel).ConfigureAwait(false)) return null;
        var length = BinaryPrimitives.ReadUInt32BigEndian(_header.AsSpan(1));
        if (length > PipeFrame.MaxPayload) throw new PipeFrameTooLongException();
        var payload = new byte[length];
        if (length > 0 && !await FillAsync(payload, cancel).ConfigureAwait(false)) throw new EndOfStreamException("The pipe closed mid-frame.");
        return new PipeFrame(_header[0], payload);
    }

    private async Task<bool> FillAsync(byte[] buffer, CancellationToken cancel)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(read), cancel).ConfigureAwait(false);
            if (n == 0)
            {
                if (read == 0) return false;
                throw new EndOfStreamException("The pipe closed mid-frame.");
            }
            read += n;
        }
        return true;
    }
}

internal static class PipeJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}

/// <summary>The tray app's first frame.</summary>
public sealed record PipeHello
{
    public int Proto { get; init; } = PipeProtocol.Version;
    public int MinProto { get; init; } = PipeProtocol.MinimumVersion;
    public string Build { get; init; } = "";
    public int Pid { get; init; }
}

/// <summary>The service's answer when it takes the tray app.</summary>
public sealed record PipeWelcome
{
    public int Proto { get; init; }
    public string Build { get; init; } = "";
    /// <summary>The account the service knows this tray app by (from its token, never from a frame).</summary>
    public string Account { get; init; } = "";
    public int Session { get; init; }
    public string InstallFolder { get; init; } = "";
}

/// <summary>The service won't take this tray app, and says why; then it closes the pipe.</summary>
public sealed record PipeRefused
{
    public const string ReasonVersion = "version", ReasonSession0 = "session0", ReasonElevated = "elevated", ReasonLowIntegrity = "low_integrity",
        ReasonNotAllowed = "not_allowed", ReasonAlreadyConnected = "already_connected", ReasonBusy = "busy";

    public string Reason { get; init; } = "";
    public int Proto { get; init; } = PipeProtocol.Version;
    public int MinProto { get; init; } = PipeProtocol.MinimumVersion;
    public string Build { get; init; } = "";
}

public static class PipeHandshake
{
    /// <summary>The version both sides speak: the lower of the two, when it is at least both minimums; null when there is none.</summary>
    public static int? Negotiate(int proto, int minProto, int peerProto, int peerMinProto)
    {
        var chosen = Math.Min(proto, peerProto);
        return chosen >= minProto && chosen >= peerMinProto ? chosen : null;
    }
}
