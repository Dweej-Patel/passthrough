using System.Net;
using Passthrough.Core.Client;

namespace Passthrough.Windows.Iroh;

/// <summary>
/// Dials another computer's shell over iroh (a port of IrohShellDialer.swift): each dial binds a fresh endpoint with an
/// ephemeral key and the host's relay (its URL and token, or n0's), and opens one stream on the shell ALPN to the
/// host's id, with its granted addresses as hints. The endpoint goes with the stream.
/// </summary>
public sealed class IrohShellDialer(IrohRelay? relayOverride = null) : IShellIrohDialer
{
    public async Task<IShellStream> ConnectAsync(string irohId, string? relayUrl, string? relayToken, IReadOnlyList<string> addresses, CancellationToken cancel)
    {
        var relay = relayOverride ?? (relayUrl is { Length: > 0 } ? new IrohRelay(relayUrl, relayToken) : IrohRelay.N0);
        var endpoint = await Task.Run(() => IrohEndpoint.Bind([], relay), cancel).ConfigureAwait(false);
        try
        {
            using var _ = cancel.Register(endpoint.Dispose);
            var stream = await Task.Run(() => endpoint.Connect(irohId, relayOverride is null ? relayUrl : null, addresses), cancel).ConfigureAwait(false);
            return new Connection(endpoint, stream);
        }
        catch
        {
            endpoint.Dispose();
            throw;
        }
    }

    public ShellPath PathOf(IShellStream stream) => stream is Connection c
        ? c.Stream.CurrentPath.Path switch { IrohPath.Direct => ShellPath.Direct, IrohPath.Relay => ShellPath.Relay, _ => ShellPath.Unknown }
        : ShellPath.Unknown;

    private sealed class Connection(IrohEndpoint endpoint, IrohStream stream) : IShellStream
    {
        public IrohStream Stream => stream;
        System.IO.Stream IShellStream.Stream => stream;
        public IPAddress? LocalAddress => null;

        public ValueTask DisposeAsync()
        {
            stream.Dispose();
            endpoint.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
