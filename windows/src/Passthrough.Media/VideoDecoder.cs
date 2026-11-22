using System.Buffers;
using System.Runtime.InteropServices;
using Passthrough.Core.Screen;
using Passthrough.Media.Interop;

namespace Passthrough.Media;

/// <summary>A decoded picture in NV12 (the Y plane, then interleaved U and V at half size), cropped to the stream's size.</summary>
public sealed class Nv12Frame : IDisposable
{
    private byte[]? _data;

    internal Nv12Frame(int width, int height, byte[] data)
    {
        Width = width;
        Height = height;
        _data = data;
    }

    public int Width { get; }
    public int Height { get; }
    /// <summary>Bytes per row of both planes: the width rounded up to even (the decoder's own padding is dropped on copy).</summary>
    public int Pitch => PitchOf(Width);
    public ReadOnlySpan<byte> Y => (_data ?? throw new ObjectDisposedException(nameof(Nv12Frame))).AsSpan(0, Pitch * Height);
    public ReadOnlySpan<byte> UV => (_data ?? throw new ObjectDisposedException(nameof(Nv12Frame))).AsSpan(Pitch * Height, Pitch * ((Height + 1) / 2));

    internal static int PitchOf(int width) => (width + 1) & ~1;
    internal static int SizeOf(int width, int height) => PitchOf(width) * (height + (height + 1) / 2);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _data, null) is { } d) ArrayPool<byte>.Shared.Return(d);
    }
}

/// <summary>The decoder couldn't take or make a picture: the view asks for a keyframe, and closes after three in 10 s.</summary>
public sealed class DecodeException(string message, Exception? inner = null) : IOException(message, inner);

/// <summary>
/// Media Foundation's decoder for the Mac's stream (synchronous transforms only): Microsoft's H.264 decoder, or a sync
/// HEVC decoder that is D3D11-aware and takes the device manager (the HEVC Video Extensions'). With a hardware D3D11
/// device it decodes on the GPU (DXVA) and the picture is read back through Media Foundation's own buffer lock; without
/// one, in software. It is told the size that Core checked (<see cref="ScreenVideoClient.CheckFormat"/>) and closes if
/// the decoder's output differs from it by more than its 16-pixel alignment. One thread uses an instance at a time.
/// </summary>
public sealed class VideoDecoder : IDisposable
{
    private static readonly Lock StartLock = new();
    private static int _started;

    private readonly ScreenCodec _codec;
    private readonly int _width, _height;
    private IMFTransform? _transform;
    private IMFDXGIDeviceManager? _manager;
    private IntPtr _device;
    private bool _providesSamples;
    private int _outputSize;
    private int _outputWidth, _outputHeight, _outputStride;

    /// <summary>Starts Media Foundation for the process (once); false when it isn't on this PC (Windows N without the Media Feature Pack, Server Core).</summary>
    public static bool Start()
    {
        lock (StartLock)
        {
            if (_started != 0) return _started > 0;
            try { _started = MF.MFStartup(MF.Version, 0) >= 0 ? 1 : -1; }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { _started = -1; }
            return _started > 0;
        }
    }

    private static int _hevc; // 0 unknown, 1 yes, -1 no

    /// <summary>
    /// Whether this PC decodes HEVC the way the stream needs: a synchronous decoder that activates, is D3D11-aware and takes
    /// a hardware device's manager. Probed once and kept; ask it off the UI thread. HEVC is offered to the Mac only then.
    /// </summary>
    public static bool HevcAvailable()
    {
        if (_hevc != 0) return _hevc > 0;
        var ok = false;
        try
        {
            using var probe = new VideoDecoder(ScreenCodec.Hevc, 1280, 720, hardware: true);
            ok = probe.IsHardware;
        }
        catch (Exception e) when (e is DecodeException or COMException or InvalidCastException) { }
        _hevc = ok ? 1 : -1;
        return ok;
    }

    /// <summary>What to offer in <c>hello</c>: H.264 always, HEVC when <see cref="HevcAvailable"/>.</summary>
    public static ScreenCodecs Decodable() => ScreenCodecs.H264 | (HevcAvailable() ? ScreenCodecs.Hevc : ScreenCodecs.None);

    /// <param name="width">The checked stream width (16…4096).</param>
    /// <param name="height">The checked stream height.</param>
    /// <param name="hardware">Use a hardware D3D11 device when there is one (false: software decode only).</param>
    public VideoDecoder(ScreenCodec codec, int width, int height, bool hardware = true)
    {
        if (width is < ScreenVideoClient.MinStreamSide or > ScreenVideoClient.MaxStreamSide || height is < ScreenVideoClient.MinStreamSide or > ScreenVideoClient.MaxStreamSide)
            throw new ArgumentOutOfRangeException(nameof(width), "A size Core would not have passed.");
        if (!Start()) throw new DecodeException("Media Foundation isn't available on this PC.");
        _codec = codec;
        _width = width;
        _height = height;
        try
        {
            _transform = codec == ScreenCodec.H264 ? CreateH264() : CreateHevc();
            if (hardware) TryUseHardware();
            if (codec == ScreenCodec.Hevc && !IsHardware) throw new DecodeException("No hardware-backed HEVC decoder here.");
            if (_transform.GetAttributes(out var attributes) >= 0) attributes.SetUINT32(MF.LowLatency, 1);
            SetInputType();
            if (!TrySetOutputType()) throw new DecodeException("The decoder offers no NV12 output.");
            _transform.ProcessMessage(MF.MessageBeginStreaming, 0);
            _transform.ProcessMessage(MF.MessageStartOfStream, 0);
        }
        catch (COMException e)
        {
            Dispose();
            throw new DecodeException("The decoder couldn't start.", e);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    /// <summary>Whether a hardware D3D11 device decodes (the GPU), as opposed to the CPU.</summary>
    public bool IsHardware { get; private set; }

    private static IMFTransform CreateH264()
    {
        var type = Type.GetTypeFromCLSID(MF.H264Decoder, throwOnError: false) ?? throw new DecodeException("No H.264 decoder on this PC.");
        try { return (IMFTransform)Activator.CreateInstance(type)!; }
        catch (COMException e) { throw new DecodeException("No H.264 decoder on this PC.", e); }
    }

    private static IMFTransform CreateHevc()
    {
        var input = new MftRegisterTypeInfo { MajorType = MF.MediaTypeVideo, SubType = MF.FormatHevc };
        MF.Check(MF.MFTEnumEx(MF.CategoryVideoDecoder, MF.EnumSyncMft | MF.EnumSortAndFilter, input, 0, out var array, out var count));
        IMFTransform? chosen = null;
        try
        {
            for (var i = 0; i < count; i++)
            {
                var pointer = Marshal.ReadIntPtr(array, i * IntPtr.Size);
                var activate = (IMFActivate)Marshal.GetObjectForIUnknown(pointer);
                Marshal.Release(pointer);
                if (chosen is null && activate.ActivateObject(MF.IMFTransformId, out var created) >= 0 && created is IMFTransform transform
                    && transform.GetAttributes(out var attributes) >= 0 && attributes.GetUINT32(MF.D3D11Aware, out var aware) >= 0 && aware != 0)
                    chosen = transform;
            }
        }
        finally { Marshal.FreeCoTaskMem(array); }
        return chosen ?? throw new DecodeException("No HEVC decoder on this PC.");
    }

    /// <summary>A hardware D3D11 device (video support, multithread-protected) given to the decoder through a DXGI device manager.</summary>
    private unsafe void TryUseHardware()
    {
        if (_transform!.GetAttributes(out var attributes) < 0 || attributes.GetUINT32(MF.D3D11Aware, out var aware) < 0 || aware == 0) return;
        int[] levels = [0xb100, 0xb000];
        if (MF.D3D11CreateDevice(0, MF.DriverHardware, 0, MF.CreateBgraSupport | MF.CreateVideoSupport, levels, (uint)levels.Length, 7,
                out var device, out _, out var context) < 0) return;
        Marshal.Release(context);
        _device = device;
        var iid = MF.ID3D10Multithread;
        if (Marshal.QueryInterface(device, in iid, out var multithread) >= 0)
        {
            // ID3D10Multithread::SetMultithreadProtected is the sixth slot (after IUnknown, Enter, Leave).
            var setProtected = (delegate* unmanaged[Stdcall]<IntPtr, int, int>)(*(IntPtr**)multithread)[5];
            setProtected(multithread, 1);
            Marshal.Release(multithread);
        }
        if (MF.MFCreateDXGIDeviceManager(out var token, out var manager) < 0) return;
        if (manager.ResetDevice(device, token) < 0) return;
        var managerPointer = Marshal.GetIUnknownForObject(manager);
        try
        {
            if (_transform.ProcessMessage(MF.MessageSetD3DManager, managerPointer) < 0) return;
        }
        finally { Marshal.Release(managerPointer); }
        _manager = manager;
        IsHardware = true;
    }

    private void SetInputType()
    {
        MF.Check(MF.MFCreateMediaType(out var type));
        type.SetGUID(MF.MajorType, MF.MediaTypeVideo);
        type.SetGUID(MF.SubType, _codec == ScreenCodec.Hevc ? MF.FormatHevc : MF.FormatH264);
        type.SetUINT64(MF.FrameSize, MF.Pack(_width, _height));
        type.SetUINT64(MF.FrameRate, MF.Pack(60, 1));
        type.SetUINT64(MF.PixelAspectRatio, MF.Pack(1, 1));
        type.SetUINT32(MF.InterlaceMode, 2); // progressive
        MF.Check(_transform!.SetInputType(0, type, 0));
    }

    /// <summary>NV12 out, at a size no more than the checked one rounded up to 16 (the decoder's alignment).</summary>
    private bool TrySetOutputType()
    {
        for (uint i = 0; ; i++)
        {
            var hr = _transform!.GetOutputAvailableType(0, i, out var type);
            if (hr == MF.NoMoreTypes) return false;
            MF.Check(hr);
            if (type.GetGUID(MF.SubType, out var subtype) < 0 || subtype != MF.FormatNv12) continue;
            MF.Check(_transform.SetOutputType(0, type, 0));
            _transform.GetOutputCurrentType(0, out var current);
            MF.Check(current.GetUINT64(MF.FrameSize, out var size));
            var (w, h) = MF.Unpack(size);
            if (w < _width || h < _height || w > Align16(_width) || h > Align16(_height))
                throw new DecodeException($"The decoder's picture is {w}×{h}, not the stream's {_width}×{_height}.");
            _outputWidth = w;
            _outputHeight = h;
            _outputStride = current.GetUINT32(MF.DefaultStride, out var stride) >= 0 && (int)stride >= w ? (int)stride : w;
            _transform.GetOutputStreamInfo(0, out var info);
            _providesSamples = (info.Flags & (MF.OutputProvidesSamples | MF.OutputCanProvideSamples)) != 0;
            _outputSize = (int)info.Size;
            return true;
        }
    }

    private static int Align16(int v) => (v + 15) & ~15;

    /// <summary>
    /// Decodes one frame (Annex B, as <see cref="AnnexB.Convert"/> makes it) and returns the pictures it produced: one in
    /// low-latency mode, possibly none for the first frames. The caller disposes each. Throws <see cref="DecodeException"/>.
    /// </summary>
    public IReadOnlyList<Nv12Frame> Decode(ReadOnlySpan<byte> annexB, long number, bool keyframe)
    {
        var transform = _transform ?? throw new ObjectDisposedException(nameof(VideoDecoder));
        try
        {
            var sample = Sample(annexB, number, keyframe);
            var frames = new List<Nv12Frame>(1);
            try
            {
                var hr = transform.ProcessInput(0, sample, 0);
                if (hr == MF.NotAccepting)
                {
                    Drain(frames);
                    hr = transform.ProcessInput(0, sample, 0);
                }
                if (hr < 0) throw new DecodeException($"The decoder refused a frame (0x{hr:X8}).");
                Drain(frames);
                return frames;
            }
            catch
            {
                foreach (var f in frames) f.Dispose();
                throw;
            }
            finally { Marshal.ReleaseComObject(sample); }
        }
        catch (COMException e) { throw new DecodeException("The decoder failed.", e); }
    }

    /// <summary>Ends the stream and returns what the decoder still held.</summary>
    public IReadOnlyList<Nv12Frame> Finish()
    {
        var transform = _transform ?? throw new ObjectDisposedException(nameof(VideoDecoder));
        transform.ProcessMessage(MF.MessageEndOfStream, 0);
        transform.ProcessMessage(MF.MessageDrain, 0);
        var frames = new List<Nv12Frame>();
        Drain(frames);
        return frames;
    }

    /// <summary>Drops what the decoder holds (after a failure, before waiting for a keyframe).</summary>
    public void Flush() => _transform?.ProcessMessage(MF.MessageFlush, 0);

    private static IMFSample Sample(ReadOnlySpan<byte> data, long number, bool keyframe)
    {
        MF.Check(MF.MFCreateMemoryBuffer((uint)data.Length, out var buffer));
        buffer.Lock(out var pointer, out _, out _);
        try { Marshal.Copy(data.ToArray(), 0, pointer, data.Length); }
        finally { buffer.Unlock(); }
        buffer.SetCurrentLength((uint)data.Length);
        MF.Check(MF.MFCreateSample(out var sample));
        sample.AddBuffer(buffer);
        Marshal.ReleaseComObject(buffer); // the sample holds it
        sample.SetSampleTime(number * 10_000_000 / 60);
        sample.SetSampleDuration(10_000_000 / 60);
        if (keyframe) sample.SetUINT32(MF.CleanPoint, 1);
        return sample;
    }

    private void Drain(List<Nv12Frame> frames)
    {
        var transform = _transform!;
        for (var guard = 0; guard < 16; guard++)
        {
            IMFSample? ours = null;
            var output = new MftOutputDataBuffer();
            if (!_providesSamples)
            {
                MF.Check(MF.MFCreateMemoryBuffer((uint)Math.Max(_outputSize, _outputStride * _outputHeight * 3 / 2), out var buffer));
                MF.Check(MF.MFCreateSample(out ours));
                ours.AddBuffer(buffer);
                Marshal.ReleaseComObject(buffer);
                output.Sample = Marshal.GetComInterfaceForObject(ours, typeof(IMFSample));
            }
            var hr = transform.ProcessOutput(0, 1, ref output, out _);
            if (output.Events != 0) Marshal.Release(output.Events);
            IMFSample? produced = null;
            if (output.Sample != 0)
            {
                if (hr >= 0) produced = ours ?? (IMFSample)Marshal.GetObjectForIUnknown(output.Sample);
                Marshal.Release(output.Sample);
            }
            if (produced is null && ours is not null) Marshal.ReleaseComObject(ours);
            if (hr == MF.NeedMoreInput) return;
            if (hr == MF.StreamChange)
            {
                // A new output type: its size must still be the checked one (rounded up to 16), else this closes.
                if (!TrySetOutputType()) throw new DecodeException("The decoder changed to an output it can't give.");
                continue;
            }
            if (hr < 0) throw new DecodeException($"The decoder failed (0x{hr:X8}).");
            // Each picture is let go of at once: a hardware decoder has a small pool of surfaces and stalls without them.
            if (produced is not null)
                try { frames.Add(Copy(produced)); }
                finally { Marshal.ReleaseComObject(produced); }
        }
    }

    /// <summary>The picture out of the decoder's buffer (a GPU texture is read back by Media Foundation's lock), cropped to the stream.</summary>
    private Nv12Frame Copy(IMFSample sample)
    {
        sample.ConvertToContiguousBuffer(out var buffer);
        var chromaRows = (_height + 1) / 2;
        var outPitch = Nv12Frame.PitchOf(_width);
        var data = ArrayPool<byte>.Shared.Rent(Nv12Frame.SizeOf(_width, _height));
        IntPtr scan0;
        int pitch;
        var twoD = buffer as IMF2DBuffer;
        if (twoD is not null) twoD.Lock2D(out scan0, out pitch);
        else
        {
            buffer.Lock(out scan0, out _, out var length);
            pitch = _outputStride;
            if (length < pitch * _outputHeight * 3 / 2)
            {
                buffer.Unlock();
                Marshal.ReleaseComObject(buffer);
                ArrayPool<byte>.Shared.Return(data);
                throw new DecodeException("The decoder's picture was shorter than its size.");
            }
        }
        try
        {
            if (pitch < _outputWidth || _outputWidth < outPitch) throw new DecodeException("The decoder's rows were shorter than the picture.");
            // The UV plane starts after the Y plane's (aligned) rows.
            var uvStart = (long)pitch * _outputHeight;
            for (var row = 0; row < _height; row++)
                Marshal.Copy(scan0 + row * pitch, data, row * outPitch, _width);
            for (var row = 0; row < chromaRows; row++)
                Marshal.Copy((nint)(scan0 + uvStart + (long)row * pitch), data, outPitch * _height + row * outPitch, outPitch);
        }
        catch
        {
            ArrayPool<byte>.Shared.Return(data);
            throw;
        }
        finally
        {
            if (twoD is not null) twoD.Unlock2D();
            else buffer.Unlock();
            Marshal.ReleaseComObject(buffer);
        }
        return new Nv12Frame(_width, _height, data);
    }

    public void Dispose()
    {
        if (_transform is { } t)
        {
            _transform = null;
            try { t.ProcessMessage(MF.MessageFlush, 0); } catch (COMException) { }
            if (_manager is not null) try { t.ProcessMessage(MF.MessageSetD3DManager, 0); } catch (COMException) { }
            Marshal.FinalReleaseComObject(t);
        }
        if (_manager is { } m)
        {
            _manager = null;
            Marshal.FinalReleaseComObject(m);
        }
        if (_device != 0)
        {
            Marshal.Release(_device);
            _device = 0;
        }
    }
}
