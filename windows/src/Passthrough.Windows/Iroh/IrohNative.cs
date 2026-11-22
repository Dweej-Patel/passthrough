using System.Runtime.InteropServices;
using System.Text;

namespace Passthrough.Windows.Iroh;

/// <summary>
/// The C ABI of windows/native/iroh-bridge (passthrough_iroh.dll beside the app, loaded by full path, never from the
/// search path). Every call returns a code; the text of the last failure on this thread is <see cref="LastError"/>.
/// </summary>
internal static unsafe class IrohNative
{
    public const string LibraryName = "passthrough_iroh.dll";

    public const int Ok = 0, End = 1;
    public const int ErrArgument = -1, ErrBadHandle = -2, ErrCancelled = -3, ErrWrongAlpn = -4, ErrConnection = -5,
        ErrBind = -6, ErrTimeout = -7, ErrState = -8, ErrPanic = -99;
    public const int PathUnknown = 0, PathDirect = 1, PathRelay = 2;
    public const int CloseClean = 0, CloseApplication = 1, CloseLost = 2;
    public const int RelayDisabled = 0, RelayN0 = 1, RelayCustom = 2;

    /// <summary>
    /// The folder the bridge is loaded from: beside the app, or (the service, whose exe sits at a path that never
    /// changes) the install folder, which only administrators can write. Set before the first call.
    /// </summary>
    public static string LibraryFolder { get; set; } = AppContext.BaseDirectory;

    public static string LibraryPath => Path.Combine(LibraryFolder, LibraryName);

    public static bool IsAvailable => File.Exists(LibraryPath);

    static IrohNative()
    {
        // Resolve this assembly's imports of the bridge to the copy beside the app, and only that one.
        NativeLibrary.SetDllImportResolver(typeof(IrohNative).Assembly, (name, _, _) =>
            name == LibraryName ? NativeLibrary.Load(LibraryPath) : IntPtr.Zero);
    }

    [DllImport(LibraryName)] public static extern int pt_iroh_generate_secret_key(byte* output);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_id_of_key(byte* key, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_last_error(byte* buffer, nuint capacity);
    [DllImport(LibraryName)]
    public static extern int pt_iroh_endpoint_bind(byte* secretKey, int relayMode, byte* relayUrl, nuint relayUrlLen,
        byte* relayToken, nuint relayTokenLen, byte* alpns, nuint alpnsLen, ulong* output);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_id(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_home_relay(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_direct_addresses(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_loopback_addresses(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_wait_online(ulong handle, uint timeoutMs);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_accept(ulong handle, byte* alpn, nuint alpnLen, ulong* output);
    [DllImport(LibraryName)]
    public static extern int pt_iroh_endpoint_connect(ulong handle, byte* id, nuint idLen, byte* relayUrl, nuint relayUrlLen,
        byte* addresses, nuint addressesLen, byte* alpn, nuint alpnLen, ulong* output);
    [DllImport(LibraryName)] public static extern int pt_iroh_endpoint_close(ulong handle);
    [DllImport(LibraryName)] public static extern int pt_iroh_incoming_origin(ulong handle, int* path, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_incoming_is_validated(ulong handle);
    [DllImport(LibraryName)] public static extern int pt_iroh_incoming_retry(ulong handle);
    [DllImport(LibraryName)] public static extern int pt_iroh_incoming_cancel(ulong handle);
    [DllImport(LibraryName)] public static extern int pt_iroh_incoming_accept(ulong handle, ulong* output);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_read(ulong handle, byte* buffer, nuint capacity, nuint* read);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_write(ulong handle, byte* data, nuint len, int finish);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_close(ulong handle);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_wait_closed(ulong handle, int* kind, ulong* code);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_remote_id(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_path(ulong handle, int* path, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_stream_stats(ulong handle, byte* buffer, nuint capacity);
    [DllImport(LibraryName)] public static extern int pt_iroh_free(ulong handle);

    /// <summary>The last failure's text on this thread.</summary>
    public static string LastError => Text(static (b, c) => pt_iroh_last_error(b, c));

    public delegate int TextCall(byte* buffer, nuint capacity);

    /// <summary>Calls a text-returning export, growing the buffer when the text needs more.</summary>
    public static string Text(TextCall call)
    {
        Span<byte> small = stackalloc byte[256];
        int length;
        fixed (byte* p = small) length = call(p, (nuint)small.Length);
        if (length < 0) throw Failure(length);
        if (length <= small.Length) return Encoding.UTF8.GetString(small[..length]);
        var big = new byte[length];
        fixed (byte* p = big) length = call(p, (nuint)big.Length);
        if (length < 0) throw Failure(length);
        return Encoding.UTF8.GetString(big, 0, Math.Min(length, big.Length));
    }

    /// <summary>Throws for a failing code.</summary>
    public static int Check(int code)
    {
        if (code < 0) throw Failure(code);
        return code;
    }

    public static IrohException Failure(int code) => new(code, LastError);
}

/// <summary>An iroh call failed; <see cref="Code"/> is the bridge's.</summary>
public sealed class IrohException(int code, string message) : IOException(message.Length > 0 ? message : $"iroh error {code}")
{
    public int Code { get; } = code;

    public bool IsCancelled => Code == IrohNative.ErrCancelled;
}
