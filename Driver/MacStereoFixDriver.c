// MacStereoFixDriver.c
//
// A minimal CoreAudio audio server plug-in (HAL plug-in) that exposes one
// virtual audio device named "MacStereoFix" with an 8-channel loopback ring
// buffer. Apps writing to the device's output stream are read back from the
// device's input stream by a helper application, which downmixes to stereo
// and forwards to the user's chosen real output device.
//
// The driver itself does NO digital signal processing. It is just a circular
// buffer indexed by the host's sample clock. All downmixing happens in the
// MacStereoFix.app helper.
//
// Modeled on Apple's NullAudio sample (Apple Sample Code License).

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

#pragma mark - Configuration

#define kPlugIn_BundleID            "com.macstereofix.driver"
#define kPlugIn_FactoryUUID         "1FF711E5-A1D3-467C-B778-E9CF3EA9E6D0"

#define kBox_UID                    "MacStereoFixBox_UID"
#define kDevice_UID                 "MacStereoFixDevice_UID"
#define kDevice_ModelUID            "MacStereoFixDevice_ModelUID"
#define kDevice_Name                "MacStereoFix"
#define kDevice_Manufacturer        "MacStereoFix"

#define kChannelCount               8
#define kSampleRate                 48000.0
#define kBytesPerFrame              (kChannelCount * (UInt32)sizeof(Float32))
#define kRingBufferFrameCount       16384u
#define kRingBufferSampleCount      (kRingBufferFrameCount * kChannelCount)

enum {
    kObjectID_PlugIn                = kAudioObjectPlugInObject,
    kObjectID_Box                   = 2,
    kObjectID_Device                = 3,
    kObjectID_Stream_Input          = 4,
    kObjectID_Stream_Output         = 5,
    kObjectID_Volume_Output_Master  = 6
};

#pragma mark - State

static pthread_mutex_t  gPlugIn_StateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gPlugIn_RefCount = 0;
static AudioServerPlugInHostRef gPlugIn_Host = NULL;

static CFStringRef      gBox_Name = NULL;
static Boolean          gBox_Acquired = true;

static UInt64           gDevice_IOIsRunning = 0;
static Float64          gDevice_HostTicksPerFrame = 0.0;
static UInt64           gDevice_NumberTimeStamps = 0;
static Float64          gDevice_AnchorSampleTime = 0.0;
static UInt64           gDevice_AnchorHostTime = 0;

static bool             gStream_Input_IsActive = true;
static bool             gStream_Output_IsActive = true;

// Interleaved Float32 ring buffer shared between WriteMix and ReadInput.
static Float32          gRingBuffer[kRingBufferSampleCount];

// Master output volume (0..1 linear scalar) exposed as a volume control
// on the device. Written by coreaudiod on behalf of hardware volume keys
// and by the helper app's slider; read by the helper app to mirror onto
// the real output device. The driver itself does not attenuate audio.
static Float32          gVolume_OutputMaster = 1.0f;

// dB range reported by the output volume control.
static const Float32    kVolume_MinDB = -96.0f;
static const Float32    kVolume_MaxDB = 0.0f;

#pragma mark - Volume helpers

// Convert a 0..1 linear scalar to a dB value in [kVolume_MinDB, kVolume_MaxDB].
static Float32 MSF_VolumeScalarToDB(Float32 scalar)
{
    if (scalar <= 0.0f) return kVolume_MinDB;
    Float32 dB = 20.0f * log10f(scalar);
    if (dB < kVolume_MinDB) dB = kVolume_MinDB;
    if (dB > kVolume_MaxDB) dB = kVolume_MaxDB;
    return dB;
}

// Inverse of MSF_VolumeScalarToDB.
static Float32 MSF_VolumeDBToScalar(Float32 dB)
{
    if (dB <= kVolume_MinDB) return 0.0f;
    if (dB >= kVolume_MaxDB) return 1.0f;
    return powf(10.0f, dB / 20.0f);
}

#pragma mark - Forward declarations of the AudioServerPlugInDriverInterface

static HRESULT      MacStereoFix_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        MacStereoFix_AddRef(void* inDriver);
static ULONG        MacStereoFix_Release(void* inDriver);
static OSStatus     MacStereoFix_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     MacStereoFix_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     MacStereoFix_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     MacStereoFix_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     MacStereoFix_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     MacStereoFix_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     MacStereoFix_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean      MacStereoFix_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus     MacStereoFix_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus     MacStereoFix_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus     MacStereoFix_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus     MacStereoFix_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus     MacStereoFix_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     MacStereoFix_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     MacStereoFix_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     MacStereoFix_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     MacStereoFix_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     MacStereoFix_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     MacStereoFix_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Driver interface table

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,
    MacStereoFix_QueryInterface,
    MacStereoFix_AddRef,
    MacStereoFix_Release,
    MacStereoFix_Initialize,
    MacStereoFix_CreateDevice,
    MacStereoFix_DestroyDevice,
    MacStereoFix_AddDeviceClient,
    MacStereoFix_RemoveDeviceClient,
    MacStereoFix_PerformDeviceConfigurationChange,
    MacStereoFix_AbortDeviceConfigurationChange,
    MacStereoFix_HasProperty,
    MacStereoFix_IsPropertySettable,
    MacStereoFix_GetPropertyDataSize,
    MacStereoFix_GetPropertyData,
    MacStereoFix_SetPropertyData,
    MacStereoFix_StartIO,
    MacStereoFix_StopIO,
    MacStereoFix_GetZeroTimeStamp,
    MacStereoFix_WillDoIOOperation,
    MacStereoFix_BeginIOOperation,
    MacStereoFix_DoIOOperation,
    MacStereoFix_EndIOOperation
};

static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;

#pragma mark - Factory

// CFPlugIn will look this up by name (see Info.plist's CFPlugInFactories).
// It must be exported even though we build with -fvisibility=hidden.
__attribute__((visibility("default")))
void* MacStereoFix_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
__attribute__((visibility("default")))
void* MacStereoFix_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    return gAudioServerPlugInDriverRef;
}

#pragma mark - IUnknown

static HRESULT MacStereoFix_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (theRequestedUUID == NULL) return kAudioHardwareIllegalOperationError;

    HRESULT theAnswer = 0;
    if (CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
    } else {
        theAnswer = E_NOINTERFACE;
    }
    CFRelease(theRequestedUUID);
    return theAnswer;
}

static ULONG MacStereoFix_AddRef(void* inDriver)
{
    if (inDriver != gAudioServerPlugInDriverRef) return 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gPlugIn_RefCount < UINT32_MAX) ++gPlugIn_RefCount;
    UInt32 r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return r;
}

static ULONG MacStereoFix_Release(void* inDriver)
{
    if (inDriver != gAudioServerPlugInDriverRef) return 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gPlugIn_RefCount > 0) --gPlugIn_RefCount;
    UInt32 r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return r;
}

#pragma mark - Lifecycle

static OSStatus MacStereoFix_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    gPlugIn_Host = inHost;

    // Compute host ticks per frame for the timestamp anchoring math.
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
    theHostClockFrequency *= 1000000000.0;
    gDevice_HostTicksPerFrame = theHostClockFrequency / kSampleRate;

    // Zero the ring buffer
    memset(gRingBuffer, 0, sizeof(gRingBuffer));

    // Default box name
    if (gBox_Name == NULL) {
        gBox_Name = CFSTR("MacStereoFix");
    }
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MacStereoFix_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MacStereoFix_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Property helpers

static Boolean MacStereoFix_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL) return false;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
            }
            break;

        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioObjectPropertyIdentify:
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                case kAudioBoxPropertyBoxUID:
                case kAudioBoxPropertyTransportType:
                case kAudioBoxPropertyHasAudio:
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquired:
                case kAudioBoxPropertyAcquisitionFailed:
                case kAudioBoxPropertyDeviceList:
                    return true;
            }
            break;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIcon:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                    return true;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    return true;
            }
            break;
    }
    return false;
}

static OSStatus MacStereoFix_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    *outIsSettable = false;
    switch (inObjectID) {
        case kObjectID_Box:
            if (inAddress->mSelector == kAudioObjectPropertyName ||
                inAddress->mSelector == kAudioObjectPropertyIdentify ||
                inAddress->mSelector == kAudioBoxPropertyAcquired) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            if (inAddress->mSelector == kAudioStreamPropertyIsActive ||
                inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
                inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Volume_Output_Master:
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
                inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                *outIsSettable = true;
            }
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    *outDataSize = 0;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:                 *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer:              *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyBoxList:                   *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToBox:         *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyDeviceList:                *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice:      *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyResourceBundle:            *outDataSize = sizeof(CFStringRef); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:         *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:             *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:             *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:              *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyModelName:         *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:      *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:      *outDataSize = 0; break;
                case kAudioObjectPropertyIdentify:          *outDataSize = sizeof(UInt32); break;
                case kAudioObjectPropertySerialNumber:      *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyFirmwareVersion:   *outDataSize = sizeof(CFStringRef); break;
                case kAudioBoxPropertyBoxUID:               *outDataSize = sizeof(CFStringRef); break;
                case kAudioBoxPropertyTransportType:        *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasAudio:             *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasVideo:             *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyHasMIDI:              *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyIsProtected:          *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquired:             *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyAcquisitionFailed:    *outDataSize = sizeof(UInt32); break;
                case kAudioBoxPropertyDeviceList: {
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *outDataSize = gBox_Acquired ? sizeof(AudioObjectID) : 0;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:                 *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:                      *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:              *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 3 * sizeof(AudioObjectID); break;
                case kAudioDevicePropertyDeviceUID:                 *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyModelUID:                  *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType:             *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyRelatedDevices:            *outDataSize = sizeof(AudioObjectID); break;
                case kAudioDevicePropertyClockDomain:               *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsAlive:             *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsRunning:           *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:  *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyLatency:                   *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyStreams: {
                    UInt32 count = 0;
                    if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) count = 2;
                    else if (inAddress->mScope == kAudioObjectPropertyScopeInput) count = 1;
                    else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) count = 1;
                    *outDataSize = count * sizeof(AudioObjectID);
                    break;
                }
                case kAudioObjectPropertyControlList:
                    if (inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
                        inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    break;
                case kAudioDevicePropertySafetyOffset:              *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyNominalSampleRate:         *outDataSize = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); break;
                case kAudioDevicePropertyIsHidden:                  *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyZeroTimeStampPeriod:       *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyIcon:                      *outDataSize = sizeof(CFURLRef); break;
                case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); break;
                case kAudioDevicePropertyPreferredChannelLayout:    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription)); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:             *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                 *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                 *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:                  *outDataSize = sizeof(CFStringRef); break;
                case kAudioStreamPropertyIsActive:              *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyDirection:             *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyTerminalType:          *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyStartingChannel:       *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyLatency:               *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:        *outDataSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = sizeof(AudioStreamRangedDescription); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:                     *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:                         *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:                         *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:                  *outDataSize = 0; break;
                case kAudioControlPropertyScope:                        *outDataSize = sizeof(AudioObjectPropertyScope); break;
                case kAudioControlPropertyElement:                      *outDataSize = sizeof(AudioObjectPropertyElement); break;
                case kAudioLevelControlPropertyScalarValue:             *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelValue:            *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelRange:            *outDataSize = sizeof(AudioValueRange); break;
                case kAudioLevelControlPropertyConvertScalarToDecibels: *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyConvertDecibelsToScalar: *outDataSize = sizeof(Float32); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    UInt32 written = 0;
    OSStatus status = kAudioHardwareNoError;

    switch (inObjectID) {

    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *((AudioClassID*)outData) = kAudioObjectClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *((AudioClassID*)outData) = kAudioPlugInClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
                written = sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyOwnedObjects: {
                UInt32 count = inDataSize / sizeof(AudioObjectID);
                if (count >= 1) ((AudioObjectID*)outData)[0] = kObjectID_Box;
                written = (count >= 1 ? 1 : 0) * sizeof(AudioObjectID);
                break;
            }
            case kAudioPlugInPropertyBoxList: {
                UInt32 count = inDataSize / sizeof(AudioObjectID);
                if (count >= 1) ((AudioObjectID*)outData)[0] = kObjectID_Box;
                written = (count >= 1 ? 1 : 0) * sizeof(AudioObjectID);
                break;
            }
            case kAudioPlugInPropertyTranslateUIDToBox: {
                if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *((CFStringRef*)inQualifierData);
                if (uid != NULL && CFStringCompare(uid, CFSTR(kBox_UID), 0) == kCFCompareEqualTo) {
                    *((AudioObjectID*)outData) = kObjectID_Box;
                } else {
                    *((AudioObjectID*)outData) = kAudioObjectUnknown;
                }
                written = sizeof(AudioObjectID);
                break;
            }
            case kAudioPlugInPropertyDeviceList: {
                UInt32 count = inDataSize / sizeof(AudioObjectID);
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean acquired = gBox_Acquired;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                UInt32 needed = acquired ? 1 : 0;
                if (needed > count) needed = count;
                if (needed >= 1) ((AudioObjectID*)outData)[0] = kObjectID_Device;
                written = needed * sizeof(AudioObjectID);
                break;
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *((CFStringRef*)inQualifierData);
                if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
                    *((AudioObjectID*)outData) = kObjectID_Device;
                } else {
                    *((AudioObjectID*)outData) = kAudioObjectUnknown;
                }
                written = sizeof(AudioObjectID);
                break;
            }
            case kAudioPlugInPropertyResourceBundle:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *((CFStringRef*)outData) = CFSTR("");
                written = sizeof(CFStringRef);
                break;
            default:
                status = kAudioHardwareUnknownPropertyError;
                break;
        }
        break;

    case kObjectID_Box:
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioBoxClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kObjectID_PlugIn;
                written = sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyName: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                CFStringRef name = gBox_Name;
                if (name) CFRetain(name);
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *((CFStringRef*)outData) = name;
                written = sizeof(CFStringRef);
                break;
            }
            case kAudioObjectPropertyModelName:
                *((CFStringRef*)outData) = CFSTR("MacStereoFix Box");
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyOwnedObjects:
                written = 0;
                break;
            case kAudioObjectPropertyIdentify:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioObjectPropertySerialNumber:
                *((CFStringRef*)outData) = CFSTR("00000000");
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyFirmwareVersion:
                *((CFStringRef*)outData) = CFSTR("1.0");
                written = sizeof(CFStringRef);
                break;
            case kAudioBoxPropertyBoxUID:
                *((CFStringRef*)outData) = CFSTR(kBox_UID);
                written = sizeof(CFStringRef);
                break;
            case kAudioBoxPropertyTransportType:
                *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                written = sizeof(UInt32);
                break;
            case kAudioBoxPropertyHasAudio:
                *((UInt32*)outData) = 1;
                written = sizeof(UInt32);
                break;
            case kAudioBoxPropertyHasVideo:
            case kAudioBoxPropertyHasMIDI:
            case kAudioBoxPropertyIsProtected:
            case kAudioBoxPropertyAcquisitionFailed:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioBoxPropertyAcquired: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((UInt32*)outData) = gBox_Acquired ? 1 : 0;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                written = sizeof(UInt32);
                break;
            }
            case kAudioBoxPropertyDeviceList: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean acquired = gBox_Acquired;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                if (acquired && inDataSize >= sizeof(AudioObjectID)) {
                    ((AudioObjectID*)outData)[0] = kObjectID_Device;
                    written = sizeof(AudioObjectID);
                } else {
                    written = 0;
                }
                break;
            }
            default:
                status = kAudioHardwareUnknownPropertyError;
                break;
        }
        break;

    case kObjectID_Device:
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioDeviceClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kObjectID_PlugIn;
                written = sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyName:
                *((CFStringRef*)outData) = CFSTR(kDevice_Name);
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                written = sizeof(CFStringRef);
                break;
            case kAudioObjectPropertyOwnedObjects: {
                UInt32 maxCount = inDataSize / sizeof(AudioObjectID);
                if (maxCount > 3) maxCount = 3;
                if (maxCount >= 1) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
                if (maxCount >= 2) ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
                if (maxCount >= 3) ((AudioObjectID*)outData)[2] = kObjectID_Volume_Output_Master;
                written = maxCount * sizeof(AudioObjectID);
                break;
            }
            case kAudioDevicePropertyDeviceUID:
                *((CFStringRef*)outData) = CFSTR(kDevice_UID);
                written = sizeof(CFStringRef);
                break;
            case kAudioDevicePropertyModelUID:
                *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
                written = sizeof(CFStringRef);
                break;
            case kAudioDevicePropertyTransportType:
                *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyRelatedDevices: {
                if (inDataSize >= sizeof(AudioObjectID)) {
                    ((AudioObjectID*)outData)[0] = kObjectID_Device;
                    written = sizeof(AudioObjectID);
                }
                break;
            }
            case kAudioDevicePropertyClockDomain:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyDeviceIsAlive:
                *((UInt32*)outData) = 1;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyDeviceIsRunning: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((UInt32*)outData) = (gDevice_IOIsRunning > 0) ? 1 : 0;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                written = sizeof(UInt32);
                break;
            }
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                *((UInt32*)outData) = 1;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *((UInt32*)outData) = 1;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyLatency:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyStreams: {
                UInt32 maxCount = inDataSize / sizeof(AudioObjectID);
                UInt32 idx = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    if (idx < maxCount) ((AudioObjectID*)outData)[idx++] = kObjectID_Stream_Input;
                }
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    if (idx < maxCount) ((AudioObjectID*)outData)[idx++] = kObjectID_Stream_Output;
                }
                written = idx * sizeof(AudioObjectID);
                break;
            }
            case kAudioObjectPropertyControlList: {
                UInt32 maxCount = inDataSize / sizeof(AudioObjectID);
                if ((inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
                     inAddress->mScope == kAudioObjectPropertyScopeOutput) &&
                    maxCount >= 1) {
                    ((AudioObjectID*)outData)[0] = kObjectID_Volume_Output_Master;
                    written = sizeof(AudioObjectID);
                } else {
                    written = 0;
                }
                break;
            }
            case kAudioDevicePropertySafetyOffset:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyNominalSampleRate:
                *((Float64*)outData) = kSampleRate;
                written = sizeof(Float64);
                break;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                UInt32 maxCount = inDataSize / sizeof(AudioValueRange);
                if (maxCount >= 1) {
                    ((AudioValueRange*)outData)[0].mMinimum = kSampleRate;
                    ((AudioValueRange*)outData)[0].mMaximum = kSampleRate;
                    written = sizeof(AudioValueRange);
                }
                break;
            }
            case kAudioDevicePropertyIsHidden:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *((UInt32*)outData) = kRingBufferFrameCount;
                written = sizeof(UInt32);
                break;
            case kAudioDevicePropertyIcon:
                *((CFURLRef*)outData) = NULL;
                written = sizeof(CFURLRef);
                break;
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
                written = 2 * sizeof(UInt32);
                break;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 needed = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription)));
                if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mChannelBitmap = 0;
                layout->mNumberChannelDescriptions = kChannelCount;
                AudioChannelLabel labels[kChannelCount] = {
                    kAudioChannelLabel_Left,
                    kAudioChannelLabel_Right,
                    kAudioChannelLabel_Center,
                    kAudioChannelLabel_LFEScreen,
                    kAudioChannelLabel_LeftSurround,
                    kAudioChannelLabel_RightSurround,
                    kAudioChannelLabel_LeftSurroundDirect,
                    kAudioChannelLabel_RightSurroundDirect
                };
                for (UInt32 i = 0; i < kChannelCount; ++i) {
                    layout->mChannelDescriptions[i].mChannelLabel = labels[i];
                    layout->mChannelDescriptions[i].mChannelFlags = 0;
                    layout->mChannelDescriptions[i].mCoordinates[0] = 0;
                    layout->mChannelDescriptions[i].mCoordinates[1] = 0;
                    layout->mChannelDescriptions[i].mCoordinates[2] = 0;
                }
                written = needed;
                break;
            }
            default:
                status = kAudioHardwareUnknownPropertyError;
                break;
        }
        break;

    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output: {
        bool isInput = (inObjectID == kObjectID_Stream_Input);
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioStreamClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kObjectID_Device;
                written = sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyName:
                *((CFStringRef*)outData) = isInput ? CFSTR("MacStereoFix Input") : CFSTR("MacStereoFix Output");
                written = sizeof(CFStringRef);
                break;
            case kAudioStreamPropertyIsActive: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((UInt32*)outData) = (isInput ? gStream_Input_IsActive : gStream_Output_IsActive) ? 1 : 0;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                written = sizeof(UInt32);
                break;
            }
            case kAudioStreamPropertyDirection:
                *((UInt32*)outData) = isInput ? 1 : 0;
                written = sizeof(UInt32);
                break;
            case kAudioStreamPropertyTerminalType:
                *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                written = sizeof(UInt32);
                break;
            case kAudioStreamPropertyStartingChannel:
                *((UInt32*)outData) = 1;
                written = sizeof(UInt32);
                break;
            case kAudioStreamPropertyLatency:
                *((UInt32*)outData) = 0;
                written = sizeof(UInt32);
                break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                AudioStreamBasicDescription* fmt = (AudioStreamBasicDescription*)outData;
                fmt->mSampleRate       = kSampleRate;
                fmt->mFormatID         = kAudioFormatLinearPCM;
                fmt->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                fmt->mBytesPerPacket   = kBytesPerFrame;
                fmt->mFramesPerPacket  = 1;
                fmt->mBytesPerFrame    = kBytesPerFrame;
                fmt->mChannelsPerFrame = kChannelCount;
                fmt->mBitsPerChannel   = 32;
                fmt->mReserved         = 0;
                written = sizeof(AudioStreamBasicDescription);
                break;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
                AudioStreamRangedDescription* d = (AudioStreamRangedDescription*)outData;
                d->mFormat.mSampleRate       = kSampleRate;
                d->mFormat.mFormatID         = kAudioFormatLinearPCM;
                d->mFormat.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                d->mFormat.mBytesPerPacket   = kBytesPerFrame;
                d->mFormat.mFramesPerPacket  = 1;
                d->mFormat.mBytesPerFrame    = kBytesPerFrame;
                d->mFormat.mChannelsPerFrame = kChannelCount;
                d->mFormat.mBitsPerChannel   = 32;
                d->mFormat.mReserved         = 0;
                d->mSampleRateRange.mMinimum = kSampleRate;
                d->mSampleRateRange.mMaximum = kSampleRate;
                written = sizeof(AudioStreamRangedDescription);
                break;
            }
            default:
                status = kAudioHardwareUnknownPropertyError;
                break;
        }
        break;
    }

    case kObjectID_Volume_Output_Master:
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *((AudioClassID*)outData) = kAudioLevelControlClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *((AudioClassID*)outData) = kAudioVolumeControlClassID;
                written = sizeof(AudioClassID);
                break;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *((AudioObjectID*)outData) = kObjectID_Device;
                written = sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyOwnedObjects:
                written = 0;
                break;
            case kAudioControlPropertyScope:
                if (inDataSize < sizeof(AudioObjectPropertyScope)) return kAudioHardwareBadPropertySizeError;
                *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
                written = sizeof(AudioObjectPropertyScope);
                break;
            case kAudioControlPropertyElement:
                if (inDataSize < sizeof(AudioObjectPropertyElement)) return kAudioHardwareBadPropertySizeError;
                *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
                written = sizeof(AudioObjectPropertyElement);
                break;
            case kAudioLevelControlPropertyScalarValue: {
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *((Float32*)outData) = gVolume_OutputMaster;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                written = sizeof(Float32);
                break;
            }
            case kAudioLevelControlPropertyDecibelValue: {
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Float32 scalar = gVolume_OutputMaster;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *((Float32*)outData) = MSF_VolumeScalarToDB(scalar);
                written = sizeof(Float32);
                break;
            }
            case kAudioLevelControlPropertyDecibelRange: {
                if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                AudioValueRange* r = (AudioValueRange*)outData;
                r->mMinimum = kVolume_MinDB;
                r->mMaximum = kVolume_MaxDB;
                written = sizeof(AudioValueRange);
                break;
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels: {
                // On input, outData contains a scalar value; we overwrite
                // it with the equivalent dB value.
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32 scalar = *((Float32*)outData);
                if (scalar < 0.0f) scalar = 0.0f;
                if (scalar > 1.0f) scalar = 1.0f;
                *((Float32*)outData) = MSF_VolumeScalarToDB(scalar);
                written = sizeof(Float32);
                break;
            }
            case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                // On input, outData contains a dB value; we overwrite it
                // with the equivalent scalar value.
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32 dB = *((Float32*)outData);
                *((Float32*)outData) = MSF_VolumeDBToScalar(dB);
                written = sizeof(Float32);
                break;
            }
            default:
                status = kAudioHardwareUnknownPropertyError;
                break;
        }
        break;

    default:
        status = kAudioHardwareBadObjectError;
        break;
    }

    *outDataSize = written;
    return status;
}

static OSStatus MacStereoFix_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_Box:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyName: {
                    if (inDataSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    CFStringRef newName = *((CFStringRef*)inData);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if (gBox_Name != NULL) CFRelease(gBox_Name);
                    if (newName != NULL) CFRetain(newName);
                    gBox_Name = newName;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyIdentify:
                    return kAudioHardwareNoError;
                case kAudioBoxPropertyAcquired: {
                    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    gBox_Acquired = (*(UInt32*)inData != 0);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyIsActive: {
                    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    bool active = (*(UInt32*)inData != 0);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if (inObjectID == kObjectID_Stream_Input) gStream_Input_IsActive = active;
                    else gStream_Output_IsActive = active;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    const AudioStreamBasicDescription* fmt = (const AudioStreamBasicDescription*)inData;
                    if (fmt->mFormatID != kAudioFormatLinearPCM) return kAudioDeviceUnsupportedFormatError;
                    if (fmt->mChannelsPerFrame != kChannelCount) return kAudioDeviceUnsupportedFormatError;
                    if (fmt->mSampleRate != kSampleRate) return kAudioHardwareIllegalOperationError;
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioLevelControlPropertyScalarValue: {
                    if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    Float32 newScalar = *((const Float32*)inData);
                    if (newScalar < 0.0f) newScalar = 0.0f;
                    if (newScalar > 1.0f) newScalar = 1.0f;
                    bool changed = false;
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if (gVolume_OutputMaster != newScalar) {
                        gVolume_OutputMaster = newScalar;
                        changed = true;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    if (changed && gPlugIn_Host != NULL) {
                        // Notify on both scalar and decibel since they are
                        // two views of the same underlying value. Do this
                        // OUTSIDE the mutex — PropertiesChanged can dispatch
                        // to listeners that re-enter the driver.
                        AudioObjectPropertyAddress changedAddrs[2] = {
                            { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                        };
                        gPlugIn_Host->PropertiesChanged(gPlugIn_Host,
                                                        kObjectID_Volume_Output_Master,
                                                        2, changedAddrs);
                    }
                    return kAudioHardwareNoError;
                }
                case kAudioLevelControlPropertyDecibelValue: {
                    if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    Float32 newDB = *((const Float32*)inData);
                    if (newDB < kVolume_MinDB) newDB = kVolume_MinDB;
                    if (newDB > kVolume_MaxDB) newDB = kVolume_MaxDB;
                    Float32 newScalar = MSF_VolumeDBToScalar(newDB);
                    bool changed = false;
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if (gVolume_OutputMaster != newScalar) {
                        gVolume_OutputMaster = newScalar;
                        changed = true;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    if (changed && gPlugIn_Host != NULL) {
                        AudioObjectPropertyAddress changedAddrs[2] = {
                            { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                        };
                        gPlugIn_Host->PropertiesChanged(gPlugIn_Host,
                                                        kObjectID_Volume_Output_Master,
                                                        2, changedAddrs);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus MacStereoFix_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gDevice_IOIsRunning == 0) {
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorSampleTime = 0.0;
        gDevice_AnchorHostTime = mach_absolute_time();
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
    }
    ++gDevice_IOIsRunning;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gDevice_IOIsRunning > 0) --gDevice_IOIsRunning;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    // No lock here: GetZeroTimeStamp is on the audio realtime path. The host
    // serialises calls per device, and gDevice_NumberTimeStamps /
    // gDevice_AnchorHostTime are only ever written from this function (or
    // reset under lock in StartIO before IO begins).
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRingBuffer = gDevice_HostTicksPerFrame * (Float64)kRingBufferFrameCount;
    Float64 hostTickOffset = ((Float64)gDevice_NumberTimeStamps + 1.0) * hostTicksPerRingBuffer;
    UInt64 nextHostTime = gDevice_AnchorHostTime + (UInt64)hostTickOffset;
    if (nextHostTime <= currentHostTime) {
        ++gDevice_NumberTimeStamps;
    }
    *outSampleTime = gDevice_NumberTimeStamps * (Float64)kRingBufferFrameCount;
    *outHostTime = gDevice_AnchorHostTime + (UInt64)((Float64)gDevice_NumberTimeStamps * hostTicksPerRingBuffer);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;

    bool willDo = false;
    bool willDoInPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
    }
    *outWillDo = willDo;
    *outWillDoInPlace = willDoInPlace;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareIllegalOperationError;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output) {
        // Game writing into the device output goes into the ring buffer.
        Float64 sampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
        UInt64 startFrame = ((UInt64)sampleTime) % kRingBufferFrameCount;
        UInt32 framesRemaining = inIOBufferFrameSize;
        const Float32* src = (const Float32*)ioMainBuffer;
        UInt64 cursor = startFrame;
        while (framesRemaining > 0) {
            UInt32 framesUntilWrap = (UInt32)(kRingBufferFrameCount - cursor);
            UInt32 chunk = framesRemaining < framesUntilWrap ? framesRemaining : framesUntilWrap;
            memcpy(&gRingBuffer[cursor * kChannelCount], src, chunk * kBytesPerFrame);
            src += chunk * kChannelCount;
            framesRemaining -= chunk;
            cursor += chunk;
            if (cursor >= kRingBufferFrameCount) cursor = 0;
        }
        return kAudioHardwareNoError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Input) {
        // Helper app reading from the device input pulls from the ring buffer.
        Float64 sampleTime = inIOCycleInfo->mInputTime.mSampleTime;
        UInt64 startFrame = ((UInt64)sampleTime) % kRingBufferFrameCount;
        UInt32 framesRemaining = inIOBufferFrameSize;
        Float32* dst = (Float32*)ioMainBuffer;
        UInt64 cursor = startFrame;
        while (framesRemaining > 0) {
            UInt32 framesUntilWrap = (UInt32)(kRingBufferFrameCount - cursor);
            UInt32 chunk = framesRemaining < framesUntilWrap ? framesRemaining : framesUntilWrap;
            memcpy(dst, &gRingBuffer[cursor * kChannelCount], chunk * kBytesPerFrame);
            dst += chunk * kChannelCount;
            framesRemaining -= chunk;
            cursor += chunk;
            if (cursor >= kRingBufferFrameCount) cursor = 0;
        }
        return kAudioHardwareNoError;
    }

    return kAudioHardwareNoError;
}

static OSStatus MacStereoFix_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
