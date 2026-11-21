namespace Passthrough.Core.Transport;

/// <summary>Opens a fresh byte stream to some endpoint (a TCP socket in production, a fake in tests).</summary>
public delegate Task<Stream> StreamConnector(CancellationToken ct);
