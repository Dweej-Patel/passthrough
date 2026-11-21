using System.Buffers.Binary;
using System.Text;
using Passthrough.Core.Pipe;

namespace Passthrough.Core.Client;

/// <summary>
/// The pipe between the tray app and <c>passthrough-term.exe</c> (stage 8 a5; LocalTerminalWire.swift's shape): a byte
/// of kind, a big-endian u32 length, the payload. The console sends its size first, then keys and resizes; the tray
/// app sends the shell's output, a status line, and the end.
/// </summary>
public static class TermWire
{
    public const byte Hello = 1, Input = 2, Resize = 3, Output = 16, Status = 17, Ended = 18;

    public static PipeFrame Size(byte kind, int cols, int rows)
    {
        var payload = new byte[4];
        BinaryPrimitives.WriteUInt16BigEndian(payload, (ushort)Math.Clamp(cols, 1, 1000));
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(2), (ushort)Math.Clamp(rows, 1, 1000));
        return new PipeFrame(kind, payload);
    }

    public static (int Cols, int Rows)? ReadSize(PipeFrame frame) =>
        frame.Payload.Length >= 4 ? (BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.Span), BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.Span[2..])) : null;

    public static PipeFrame Text(byte kind, string text) => new(kind, Encoding.UTF8.GetBytes(text));

    public static PipeFrame EndedWith(int status)
    {
        var payload = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(payload, status);
        return new PipeFrame(Ended, payload);
    }

    public static int ReadStatus(PipeFrame frame) => frame.Payload.Length >= 4 ? BinaryPrimitives.ReadInt32BigEndian(frame.Payload.Span) : -1;
}
