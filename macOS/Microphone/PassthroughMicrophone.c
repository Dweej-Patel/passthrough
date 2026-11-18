// The phone's microphone as an input device on the Mac ("Passthrough Microphone"),
// for apps that listen to a microphone (dictation, calls). A Core Audio server
// plug-in: coreaudiod loads it from /Library/Audio/Plug-Ins/HAL (the root helper
// puts it there) into its sandboxed driver host.
//
// The device is a loopback: what is played to its output stream is what its input
// stream records, on the same clock. The Mac app plays the phone's voice to the
// output (ScreenHost's PhoneVoicePlayer); the output can't be chosen as the Mac's
// speaker, so nothing else plays there by accident. With nothing played, the
// input is silence.
//
// One device, two streams (one in, one out), mono 32-bit float at 48 kHz, no
// controls. The clock is the host's: a zero time stamp every kPeriodFrames.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>

// What ScreenHost looks the device up by (VirtualMicrophone.deviceUID).
#define kDeviceUID CFSTR("PassthroughMicrophone")
#define kDeviceModelUID CFSTR("PassthroughMicrophoneModel")
#define kDeviceName CFSTR("Passthrough Microphone")
#define kManufacturer CFSTR("Passthrough")

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
    kObjectID_Stream_Output = 4,
};

#define kSampleRate 48000.0
#define kChannels 1
#define kBytesPerFrame (kChannels * sizeof(Float32))
// A power of two: sample times index the ring by their low bits. 1.4 s.
#define kRingFrames 65536
#define kPeriodFrames 16384

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Boolean gInputActive = true;
static Boolean gOutputActive = true;

// The clock and the ring: IO threads and StartIO/StopIO.
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gTimeStamps = 0;
static UInt64 gAnchorHostTime = 0;
static Float32 gRing[kRingFrames];
// One past the last sample time written: what the input may read is the ring's length before it.
static SInt64 gWrittenEnd = 0;

// MARK: The ring

static void RingWrite(SInt64 start, const Float32* source, UInt32 frames) {
    if (start < 0) return;
    // Nothing was played between the last write and this one: silence there.
    if (start > gWrittenEnd) {
        SInt64 gap = start - gWrittenEnd;
        if (gap >= kRingFrames) {
            memset(gRing, 0, sizeof(gRing));
        } else {
            for (SInt64 t = gWrittenEnd; t < start; t++) gRing[t & (kRingFrames - 1)] = 0;
        }
    }
    for (UInt32 i = 0; i < frames; i++) gRing[(start + i) & (kRingFrames - 1)] = source[i];
    if (start + frames > gWrittenEnd) gWrittenEnd = start + frames;
}

static void RingRead(SInt64 start, Float32* destination, UInt32 frames) {
    for (UInt32 i = 0; i < frames; i++) {
        SInt64 t = start + i;
        Boolean written = t >= 0 && t < gWrittenEnd && t >= gWrittenEnd - kRingFrames;
        destination[i] = written ? gRing[t & (kRingFrames - 1)] : 0;
    }
}

// MARK: Formats

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

static Boolean IsOurFormat(const AudioStreamBasicDescription* format) {
    AudioStreamBasicDescription ours = Format();
    return format->mSampleRate == ours.mSampleRate && format->mFormatID == ours.mFormatID
        && format->mFormatFlags == ours.mFormatFlags && format->mChannelsPerFrame == ours.mChannelsPerFrame
        && format->mBitsPerChannel == ours.mBitsPerChannel && format->mBytesPerFrame == ours.mBytesPerFrame;
}

// MARK: Properties

static Boolean IsStream(AudioObjectID object) {
    return object == kObjectID_Stream_Input || object == kObjectID_Stream_Output;
}

static Boolean HasProperty(AudioObjectID object, const AudioObjectPropertyAddress* address) {
    switch (object) {
    case kObjectID_PlugIn:
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            return address->mScope == kAudioObjectPropertyScopeInput || address->mScope == kAudioObjectPropertyScopeOutput;
        }
        return false;
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static Boolean IsSettable(AudioObjectID object, const AudioObjectPropertyAddress* address) {
    if (!IsStream(object)) return false;
    switch (address->mSelector) {
    case kAudioStreamPropertyIsActive: case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        return true;
    }
    return false;
}

// As many of `ids` as fit `dataSize`, or (no `data`) the size of them all.
static OSStatus ReturnIDs(const AudioObjectID* ids, UInt32 count, UInt32 dataSize, UInt32* outSize, void* data) {
    if (data == NULL) {
        *outSize = count * sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    UInt32 fit = dataSize / sizeof(AudioObjectID);
    if (fit > count) fit = count;
    if (fit > 0) memcpy(data, ids, fit * sizeof(AudioObjectID));
    *outSize = fit * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

// One value of `type`: its size, or (with `data`) the value.
#define RETURN_VALUE(type, value) do { \
        *outSize = sizeof(type); \
        if (data != NULL) { \
            if (dataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *((type*)data) = (value); \
        } \
        return kAudioHardwareNoError; \
    } while (0)

// The property's data, or with `data` NULL only its size.
static OSStatus GetProperty(AudioObjectID object, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                            const void* qualifier, UInt32 dataSize, UInt32* outSize, void* data) {
    if (!HasProperty(object, address)) return kAudioHardwareUnknownPropertyError;

    if (object == kObjectID_PlugIn) {
        static const AudioObjectID devices[] = { kObjectID_Device };
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return ReturnIDs(devices, 1, dataSize, outSize, data);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (data == NULL) { *outSize = sizeof(AudioObjectID); return kAudioHardwareNoError; }
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef*)qualifier);
            Boolean ours = uid != NULL && CFStringCompare(uid, kDeviceUID, 0) == kCFCompareEqualTo;
            *((AudioObjectID*)data) = ours ? kObjectID_Device : kAudioObjectUnknown;
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        }
    }

    if (object == kObjectID_Device) {
        static const AudioObjectID both[] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
        Boolean input = address->mScope == kAudioObjectPropertyScopeInput;
        Boolean output = address->mScope == kAudioObjectPropertyScopeOutput;
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, kDeviceName);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, kDeviceUID);
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, kDeviceModelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gIOMutex);
            UInt32 running = gIOCount > 0 ? 1 : 0;
            pthread_mutex_unlock(&gIOMutex);
            RETURN_VALUE(UInt32, running);
        }
        // A microphone to choose, never the Mac's speaker: only the app plays to it, by its UID.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, input ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kPeriodFrames);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (data == NULL) { *outSize = sizeof(AudioValueRange); return kAudioHardwareNoError; }
            if (dataSize < sizeof(AudioValueRange)) { *outSize = 0; return kAudioHardwareNoError; }
            ((AudioValueRange*)data)->mMinimum = kSampleRate;
            ((AudioValueRange*)data)->mMaximum = kSampleRate;
            *outSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID related[] = { kObjectID_Device };
            return ReturnIDs(related, 1, dataSize, outSize, data);
        }
        case kAudioObjectPropertyControlList:
            return ReturnIDs(NULL, 0, dataSize, outSize, data);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (input) return ReturnIDs(&both[0], 1, dataSize, outSize, data);
            if (output) return ReturnIDs(&both[1], 1, dataSize, outSize, data);
            return ReturnIDs(both, 2, dataSize, outSize, data);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            *outSize = 2 * sizeof(UInt32);
            if (data != NULL) {
                if (dataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)data)[0] = 1;
                ((UInt32*)data)[1] = 1;
            }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            *outSize = size;
            if (data != NULL) {
                if (dataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = (AudioChannelLayout*)data;
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            }
            return kAudioHardwareNoError;
        }
        }
    }

    if (IsStream(object)) {
        Boolean input = object == kObjectID_Stream_Input;
        switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, dataSize, outSize, data);
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 active = (input ? gInputActive : gOutputActive) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, active);
        }
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, input ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (data == NULL) { *outSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError; }
            if (dataSize < sizeof(AudioStreamRangedDescription)) { *outSize = 0; return kAudioHardwareNoError; }
            AudioStreamRangedDescription* ranged = (AudioStreamRangedDescription*)data;
            ranged->mFormat = Format();
            ranged->mSampleRateRange.mMinimum = kSampleRate;
            ranged->mSampleRateRange.mMaximum = kSampleRate;
            *outSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: The driver interface

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface* gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    if (driver != gDriver || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    Boolean known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) { *outInterface = NULL; return E_NOINTERFACE; }
    pthread_mutex_lock(&gStateMutex);
    gRefCount++;
    pthread_mutex_unlock(&gStateMutex);
    *outInterface = gDriver;
    return kAudioHardwareNoError;
}

static ULONG AddRef(void* driver) {
    if (driver != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void* driver) {
    if (driver != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    gHost = host;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = ((Float64)timebase.denom / (Float64)timebase.numer) * 1000000000.0;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                             const AudioServerPlugInClientInfo* client, AudioObjectID* outDevice) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo* client) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo* client) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void* info) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void* info) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static Boolean DriverHasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                 const AudioObjectPropertyAddress* address) {
    return driver == gDriver && address != NULL && HasProperty(object, address);
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                   const AudioObjectPropertyAddress* address, Boolean* outSettable) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    if (address == NULL || outSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(object, address)) return kAudioHardwareUnknownPropertyError;
    *outSettable = IsSettable(object, address);
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                    const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
                                    UInt32* outSize) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    if (address == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(object, address, qualifierSize, qualifier, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
                                UInt32 dataSize, UInt32* outSize, void* data) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    if (address == NULL || outSize == NULL || data == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(object, address, qualifierSize, qualifier, dataSize, outSize, data);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                                const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
                                UInt32 dataSize, const void* data) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    if (address == NULL || data == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(object, address)) return kAudioHardwareUnknownPropertyError;
    if (!IsSettable(object, address)) return kAudioHardwareUnsupportedOperationError;
    switch (address->mSelector) {
    case kAudioStreamPropertyIsActive: {
        if (dataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        Boolean active = *((const UInt32*)data) != 0;
        pthread_mutex_lock(&gStateMutex);
        if (object == kObjectID_Stream_Input) gInputActive = active; else gOutputActive = active;
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareNoError;
    }
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        // The one format there is: setting it changes nothing.
        if (dataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        return IsOurFormat((const AudioStreamBasicDescription*)data) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (driver != gDriver || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    OSStatus status = kAudioHardwareNoError;
    if (gIOCount == UINT64_MAX) {
        status = kAudioHardwareIllegalOperationError;
    } else if (gIOCount++ == 0) {
        // The clock starts again from zero: nothing written before means anything now.
        gTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        gWrittenEnd = 0;
        memset(gRing, 0, sizeof(gRing));
    }
    pthread_mutex_unlock(&gIOMutex);
    return status;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (driver != gDriver || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    OSStatus status = kAudioHardwareNoError;
    if (gIOCount == 0) status = kAudioHardwareIllegalOperationError; else gIOCount--;
    pthread_mutex_unlock(&gIOMutex);
    return status;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (driver != gDriver || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kPeriodFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStamps + 1) * ticksPerPeriod);
    if (next <= mach_absolute_time()) gTimeStamps++;
    *outSampleTime = (Float64)(gTimeStamps * kPeriodFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation,
                                  Boolean* outWillDo, Boolean* outInPlace) {
    if (driver != gDriver || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) *outWillDo = will;
    if (outInPlace != NULL) *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream, UInt32 client,
                              UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer,
                              void* secondaryBuffer) {
    if (driver != gDriver || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!IsStream(stream)) return kAudioHardwareBadObjectError;
    if (cycle == NULL || mainBuffer == NULL) return kAudioHardwareNoError;
    pthread_mutex_lock(&gIOMutex);
    if (operation == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_Stream_Input) {
        RingRead((SInt64)cycle->mInputTime.mSampleTime, (Float32*)mainBuffer, frames);
    } else if (operation == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_Stream_Output) {
        RingWrite((SInt64)cycle->mOutputTime.mSampleTime, (const Float32*)mainBuffer, frames);
    }
    pthread_mutex_unlock(&gIOMutex);
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation,
                               UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return driver == gDriver && device == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    DriverHasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};

// The factory Info.plist names (CFPlugInFactories).
void* PassthroughMicrophone_Create(CFAllocatorRef allocator, CFUUIDRef requestedType);
void* PassthroughMicrophone_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriver;
}
