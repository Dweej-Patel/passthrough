using System.Runtime.InteropServices;

namespace Passthrough.Media.Interop;

// Media Foundation and Direct3D 11, by hand: only the calls the decoder makes. A [ComImport] interface needs every vtable
// slot in order, so the methods this code never calls are kept as placeholders named after them (their signatures don't
// matter: they are never invoked).

#pragma warning disable IDE1006, CA1707, CA1712 // native names

[StructLayout(LayoutKind.Sequential)]
internal struct MftInputStreamInfo
{
    public long MaxLatency;
    public uint Flags, Size, MaxLookahead, Alignment;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MftOutputStreamInfo
{
    public uint Flags, Size, Alignment;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MftOutputDataBuffer
{
    public uint StreamId;
    public IntPtr Sample;
    public uint Status;
    public IntPtr Events;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MftRegisterTypeInfo
{
    public Guid MajorType, SubType;
}

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFAttributes
{
    void GetItem(); void GetItemType(); void CompareItem(); void Compare();
    [PreserveSig] int GetUINT32(in Guid key, out uint value);
    [PreserveSig] int GetUINT64(in Guid key, out ulong value);
    void GetDouble();
    [PreserveSig] int GetGUID(in Guid key, out Guid value);
    void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    [PreserveSig] int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32(in Guid key, uint value);
    void SetUINT64(in Guid key, ulong value);
    void SetDouble();
    void SetGUID(in Guid key, in Guid value);
    void SetString();
    void SetBlob(in Guid key, byte[] buffer, int size);
    void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaType
{
    void GetItem(); void GetItemType(); void CompareItem(); void Compare();
    [PreserveSig] int GetUINT32(in Guid key, out uint value);
    [PreserveSig] int GetUINT64(in Guid key, out ulong value);
    void GetDouble();
    [PreserveSig] int GetGUID(in Guid key, out Guid value);
    void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    [PreserveSig] int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32(in Guid key, uint value);
    void SetUINT64(in Guid key, ulong value);
    void SetDouble();
    void SetGUID(in Guid key, in Guid value);
    void SetString();
    void SetBlob(in Guid key, byte[] buffer, int size);
    void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
    // IMFMediaType
    void GetMajorType(); void IsCompressedFormat(); void IsEqual(); void GetRepresentation(); void FreeRepresentation();
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFSample
{
    void GetItem(); void GetItemType(); void CompareItem(); void Compare();
    [PreserveSig] int GetUINT32(in Guid key, out uint value);
    [PreserveSig] int GetUINT64(in Guid key, out ulong value);
    void GetDouble();
    [PreserveSig] int GetGUID(in Guid key, out Guid value);
    void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    [PreserveSig] int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32(in Guid key, uint value);
    void SetUINT64(in Guid key, ulong value);
    void SetDouble();
    void SetGUID(in Guid key, in Guid value);
    void SetString();
    void SetBlob(in Guid key, byte[] buffer, int size);
    void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
    // IMFSample
    void GetSampleFlags(); void SetSampleFlags();
    void GetSampleTime(out long time);
    void SetSampleTime(long time);
    void GetSampleDuration(); void SetSampleDuration(long duration);
    void GetBufferCount(out uint count);
    void GetBufferByIndex();
    void ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
    void AddBuffer(IMFMediaBuffer buffer);
    void RemoveBufferByIndex(); void RemoveAllBuffers(); void GetTotalLength(); void CopyToBuffer();
}

[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaBuffer
{
    void Lock(out IntPtr buffer, out uint maxLength, out uint currentLength);
    void Unlock();
    void GetCurrentLength(out uint length);
    void SetCurrentLength(uint length);
    void GetMaxLength(out uint length);
}

[ComImport, Guid("7DC9D5F9-9ED9-44ec-9BBF-0600BB589FBB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMF2DBuffer
{
    void Lock2D(out IntPtr scanline0, out int pitch);
    void Unlock2D();
    void GetScanline0AndPitch(); void IsContiguousFormat(); void GetContiguousLength(); void ContiguousCopyTo(); void ContiguousCopyFrom();
}

[ComImport, Guid("bf94c121-5b05-4e6f-8000-ba598961414d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFTransform
{
    void GetStreamLimits(); void GetStreamCount(); void GetStreamIDs();
    void GetInputStreamInfo(uint stream, out MftInputStreamInfo info);
    void GetOutputStreamInfo(uint stream, out MftOutputStreamInfo info);
    [PreserveSig] int GetAttributes(out IMFAttributes attributes);
    void GetInputStreamAttributes(); void GetOutputStreamAttributes(); void DeleteInputStream(); void AddInputStreams();
    [PreserveSig] int GetInputAvailableType(uint stream, uint index, out IMFMediaType type);
    [PreserveSig] int GetOutputAvailableType(uint stream, uint index, out IMFMediaType type);
    [PreserveSig] int SetInputType(uint stream, IMFMediaType? type, uint flags);
    [PreserveSig] int SetOutputType(uint stream, IMFMediaType? type, uint flags);
    void GetInputCurrentType();
    void GetOutputCurrentType(uint stream, out IMFMediaType type);
    void GetInputStatus(); void GetOutputStatus(); void SetOutputBounds(); void ProcessEvent();
    [PreserveSig] int ProcessMessage(uint message, IntPtr param);
    [PreserveSig] int ProcessInput(uint stream, IMFSample sample, uint flags);
    [PreserveSig] int ProcessOutput(uint flags, uint count, ref MftOutputDataBuffer buffers, out uint status);
}

[ComImport, Guid("7FEE9E9A-4A89-47a6-899C-B6A53A70FB67"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFActivate
{
    void GetItem(); void GetItemType(); void CompareItem(); void Compare();
    [PreserveSig] int GetUINT32(in Guid key, out uint value);
    [PreserveSig] int GetUINT64(in Guid key, out ulong value);
    void GetDouble();
    [PreserveSig] int GetGUID(in Guid key, out Guid value);
    void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    [PreserveSig] int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32(in Guid key, uint value);
    void SetUINT64(in Guid key, ulong value);
    void SetDouble();
    void SetGUID(in Guid key, in Guid value);
    void SetString();
    void SetBlob(in Guid key, byte[] buffer, int size);
    void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
    // IMFActivate
    [PreserveSig] int ActivateObject(in Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object obj);
    void ShutdownObject(); void DetachObject();
}

[ComImport, Guid("eb533d5d-2db6-40f8-97a9-494692014f07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFDXGIDeviceManager
{
    void CloseDeviceHandle(); void GetVideoService(); void LockDevice(); void OpenDeviceHandle();
    [PreserveSig] int ResetDevice(IntPtr device, uint token);
    void TestDevice(); void UnlockDevice();
}

internal static class MF
{
    public const uint Version = 0x00020070;
    public const int NeedMoreInput = unchecked((int)0xC00D6D72);
    public const int StreamChange = unchecked((int)0xC00D6D61);
    public const int NotAccepting = unchecked((int)0xC00D36B5);
    public const int NoMoreTypes = unchecked((int)0xC00D36B9);

    public const uint MessageFlush = 0, MessageDrain = 1, MessageSetD3DManager = 2;
    public const uint MessageBeginStreaming = 0x10000000, MessageEndOfStream = 0x10000002, MessageStartOfStream = 0x10000003;

    public const uint OutputProvidesSamples = 0x100, OutputCanProvideSamples = 0x200;
    public const uint OutputStatusIncomplete = 0x01000000;

    public const uint EnumSyncMft = 0x1, EnumHardware = 0x4, EnumSortAndFilter = 0x40;

    public static readonly Guid MediaTypeVideo = new("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid FormatH264 = new("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid FormatHevc = new("43564548-0000-0010-8000-00AA00389B71");
    public static readonly Guid FormatNv12 = new("3231564E-0000-0010-8000-00AA00389B71");

    public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid SubType = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid PixelAspectRatio = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid AverageBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    public static readonly Guid Mpeg2Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid MpegSequenceHeader = new("3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3");
    public static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid D3D11Aware = new("206b4fc8-fcf9-4c51-afe3-9764369e33a0");
    public static readonly Guid CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");
    public static readonly Guid CategoryVideoDecoder = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");

    public static readonly Guid H264Decoder = new("62CE7E72-4C71-4d20-B15D-452831A87D9D");
    public static readonly Guid H264Encoder = new("6CA50344-051A-4DED-9779-A43305165E35");
    public static readonly Guid IMFTransformId = new("bf94c121-5b05-4e6f-8000-ba598961414d");

    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateMediaType(out IMFMediaType type);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateSample(out IMFSample sample);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateMemoryBuffer(uint maxLength, out IMFMediaBuffer buffer);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateDXGIDeviceManager(out uint token, out IMFDXGIDeviceManager manager);
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFTEnumEx(Guid category, uint flags, in MftRegisterTypeInfo input, IntPtr output, out IntPtr activates, out uint count);

    [DllImport("d3d11.dll", ExactSpelling = true)]
    public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, int[] featureLevels, uint levels,
        uint sdkVersion, out IntPtr device, out int level, out IntPtr context);

    public const int DriverHardware = 1;
    public const uint CreateBgraSupport = 0x20, CreateVideoSupport = 0x800;
    public static readonly Guid ID3D10Multithread = new("9B7E4E00-342C-4106-A19F-4F2704F689F0");

    public static void Check(int hr)
    {
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
    }

    public static ulong Pack(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;
    public static (int High, int Low) Unpack(ulong value) => ((int)(value >> 32), (int)(value & 0xFFFFFFFF));
}
