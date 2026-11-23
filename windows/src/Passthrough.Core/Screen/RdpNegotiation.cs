using System.Buffers.Binary;

namespace Passthrough.Core.Screen;

/// <summary>
/// Network Level Authentication on every relayed connection, whatever the PC allows (stage 5 review): the first PDU
/// each way is plaintext (TPKT and X.224), so the relay reads them before it splices. The phone's connection request
/// must offer CredSSP (HYBRID or HYBRID_EX), and Remote Desktop's confirm must choose one of them; anything else is
/// closed. So each relayed connection reaches Windows' sign-in only through NLA: one credential try per connection,
/// counted by the relay's caps, never a logon screen with endless tries.
/// </summary>
public static class RdpNegotiation
{
    public const uint ProtocolSsl = 1, ProtocolHybrid = 2, ProtocolHybridEx = 8;
    private const int MaxFirstPdu = 1024;

    /// <summary>
    /// Reads the first PDU from the phone, forwards it if it offers NLA, then the confirm back if Remote Desktop chose NLA.
    /// False: close both; <paramref name="refused"/> hears which side and what its PDU was (sizes, codes and the
    /// negotiation's last 8 bytes; never the request's cookie, which names the account).
    /// </summary>
    public static async Task<bool> EnforceAsync(Stream phone, Stream desktop, CancellationToken cancel, Action<string>? refused = null)
    {
        var request = await ReadPduAsync(phone, cancel).ConfigureAwait(false);
        if (request is null || !OffersNla(request))
        {
            refused?.Invoke($"the phone's connection request {Describe(request)}");
            return false;
        }
        await desktop.WriteAsync(request, cancel).ConfigureAwait(false);
        var confirm = await ReadPduAsync(desktop, cancel).ConfigureAwait(false);
        if (confirm is null || !ChoseNla(confirm))
        {
            refused?.Invoke($"Remote Desktop's confirm {Describe(confirm)}");
            return false;
        }
        await phone.WriteAsync(confirm, cancel).ConfigureAwait(false);
        return true;
    }

    private static string Describe(byte[]? pdu) => pdu is null
        ? "wasn't a TPKT PDU of 11 to 1024 bytes, or the stream ended"
        : $"was {pdu.Length} bytes, X.224 code 0x{pdu[5]:x2}, length indicator {pdu[4]}, {Tail(pdu)}";

    /// <summary>The negotiation structure's bytes, only when the last 8 bytes are one: otherwise they are the cookie's end, which names the account.</summary>
    private static string Tail(byte[] pdu)
    {
        var tail = pdu.AsSpan(pdu.Length - 8);
        return tail[0] is >= 1 and <= 3 && BinaryPrimitives.ReadUInt16LittleEndian(tail[2..]) == 8
            ? $"negotiation {Convert.ToHexStringLower(tail)}"
            : "no negotiation structure";
    }

    /// <summary>One TPKT PDU (version 3, its length in bytes 2–3); null when it isn't one or is too long for a first PDU.</summary>
    internal static async Task<byte[]?> ReadPduAsync(Stream stream, CancellationToken cancel)
    {
        var header = new byte[4];
        try { await stream.ReadExactlyAsync(header, cancel).ConfigureAwait(false); }
        catch (EndOfStreamException) { return null; }
        if (header[0] != 0x03) return null;
        var length = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(2));
        if (length < 11 || length > MaxFirstPdu) return null;
        var pdu = new byte[length];
        header.CopyTo(pdu, 0);
        try { await stream.ReadExactlyAsync(pdu.AsMemory(4), cancel).ConfigureAwait(false); }
        catch (EndOfStreamException) { return null; }
        return pdu;
    }

    /// <summary>An X.224 connection request (0xE0) ending in an RDP negotiation request (type 1, length 8) that offers CredSSP.</summary>
    public static bool OffersNla(ReadOnlySpan<byte> pdu) =>
        pdu.Length >= 4 + 7 + 8 && (pdu[5] & 0xF0) == 0xE0 && Negotiation(pdu, 0x01) is { } requested && (requested & (ProtocolHybrid | ProtocolHybridEx)) != 0;

    /// <summary>An X.224 connection confirm (0xD0) whose RDP negotiation response (type 2) selected CredSSP.</summary>
    public static bool ChoseNla(ReadOnlySpan<byte> pdu) =>
        pdu.Length >= 4 + 7 + 8 && (pdu[5] & 0xF0) == 0xD0 && Negotiation(pdu, 0x02) is ProtocolHybrid or ProtocolHybridEx;

    /// <summary>The protocols in the last 8 bytes when they are an RDP negotiation structure of <paramref name="type"/>.</summary>
    private static uint? Negotiation(ReadOnlySpan<byte> pdu, byte type)
    {
        var tail = pdu[^8..];
        if (tail[0] != type || BinaryPrimitives.ReadUInt16LittleEndian(tail[2..]) != 8) return null;
        // The X.224 length indicator must cover the rest of the PDU, or the tail isn't what it seems.
        if (pdu[4] != pdu.Length - 5) return null;
        return BinaryPrimitives.ReadUInt32LittleEndian(tail[4..]);
    }
}
