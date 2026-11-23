namespace Passthrough.Core.Pipe;

/// <summary>Who is on the other end of the service's pipe, from that process's token (never from a frame).</summary>
public sealed record PipePeer(string Account, int Session, bool Elevated, PipePeer.Integrity Level)
{
    public enum Integrity { Untrusted, Low, Medium, High, System }
}

/// <summary>The service's rules for which tray apps it takes (stage 4 plan, section 4, "mutual checks").</summary>
public static class PipePeerPolicy
{
    /// <summary>Why <paramref name="peer"/> is refused, as a <see cref="PipeRefused"/> reason; null when it is taken.</summary>
    public static string? Refusal(PipePeer peer, IReadOnlyCollection<string> allowedAccounts)
    {
        if (peer.Session == 0) return PipeRefused.ReasonSession0;
        if (peer.Elevated || peer.Level >= PipePeer.Integrity.High) return PipeRefused.ReasonElevated;
        if (peer.Level < PipePeer.Integrity.Medium) return PipeRefused.ReasonLowIntegrity;
        if (!allowedAccounts.Contains(peer.Account, StringComparer.OrdinalIgnoreCase)) return PipeRefused.ReasonNotAllowed;
        return null;
    }
}

/// <summary>The service refused this tray app.</summary>
public sealed class PipeRefusedException(PipeRefused refused) : Exception($"The service refused: {refused.Reason}")
{
    public PipeRefused Refused { get; } = refused;
}

public static class PipeHandshakes
{
    public static readonly TimeSpan HelloLimit = TimeSpan.FromSeconds(5);

    /// <summary>The tray app's side: <c>Hello</c>, then the service's <c>Welcome</c> (or a <see cref="PipeRefusedException"/>).</summary>
    public static async Task<PipeWelcome> ClientAsync(Stream stream, PipeHello hello, CancellationToken cancel = default)
    {
        await stream.WriteAsync(PipeFrame.Json(PipeKind.Hello, hello).Encode(), cancel).ConfigureAwait(false);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(HelloLimit);
        var frame = await new PipeFrameReader(stream).ReadAsync(limit.Token).ConfigureAwait(false) ?? throw new EndOfStreamException("The service closed the pipe.");
        if (frame.Kind == PipeKind.Refused) throw new PipeRefusedException(frame.Read<PipeRefused>() ?? new PipeRefused());
        if (frame.Kind != PipeKind.Welcome || frame.Read<PipeWelcome>() is not { } welcome) throw new IOException("The service said something other than welcome.");
        if (PipeHandshake.Negotiate(hello.Proto, hello.MinProto, welcome.Proto, welcome.Proto) is null)
            throw new PipeRefusedException(new PipeRefused { Reason = PipeRefused.ReasonVersion, Proto = welcome.Proto, Build = welcome.Build });
        return welcome;
    }

    /// <summary>
    /// The service's side: the tray app's <c>Hello</c> within <see cref="HelloLimit"/> (anything else first closes),
    /// the version, then <paramref name="refusal"/>'s verdict on the peer. Returns the hello and the version spoken, or
    /// null after sending <c>Refused</c>.
    /// </summary>
    public static async Task<(PipeHello Hello, int Proto)?> ServerAsync(Stream stream, string? refusal, PipeWelcome welcome, CancellationToken cancel = default)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(HelloLimit);
        PipeFrame? frame;
        try { frame = await new PipeFrameReader(stream).ReadAsync(limit.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return null; }
        if (frame is not { Kind: PipeKind.Hello } hello || hello.Read<PipeHello>() is not { } said) return null;
        var refused = new PipeRefused { Build = welcome.Build };
        if (PipeHandshake.Negotiate(PipeProtocol.Version, PipeProtocol.MinimumVersion, said.Proto, said.MinProto) is not { } proto)
        {
            await stream.WriteAsync(PipeFrame.Json(PipeKind.Refused, refused with { Reason = PipeRefused.ReasonVersion }).Encode(), cancel).ConfigureAwait(false);
            return null;
        }
        if (refusal is not null)
        {
            await stream.WriteAsync(PipeFrame.Json(PipeKind.Refused, refused with { Reason = refusal }).Encode(), cancel).ConfigureAwait(false);
            return null;
        }
        await stream.WriteAsync(PipeFrame.Json(PipeKind.Welcome, welcome with { Proto = proto }).Encode(), cancel).ConfigureAwait(false);
        return (said, proto);
    }
}
