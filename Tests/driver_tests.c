#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include "../Driver/MacStereoFixDriver.c"

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
}

static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              UInt32 size, UInt32 *written, void *data) {
    AudioObjectPropertyAddress a = address(selector);
    return MacStereoFix_GetPropertyData(gAudioServerPlugInDriverRef, object, 0,
                                       &a, 0, NULL, size, written, data);
}

static OSStatus set_property(AudioObjectID object, AudioObjectPropertySelector selector,
                             UInt32 size, const void *data) {
    AudioObjectPropertyAddress a = address(selector);
    return MacStereoFix_SetPropertyData(gAudioServerPlugInDriverRef, object, 0,
                                       &a, 0, NULL, size, data);
}

static void test_property_bounds(void) {
    const AudioObjectPropertySelector selectors[] = {
        kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner,
        kAudioObjectPropertyName, kAudioObjectPropertyModelName, kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyIdentify,
        kAudioObjectPropertySerialNumber, kAudioObjectPropertyFirmwareVersion,
        kAudioPlugInPropertyBoxList, kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyResourceBundle,
        kAudioBoxPropertyBoxUID, kAudioBoxPropertyTransportType, kAudioBoxPropertyHasAudio,
        kAudioBoxPropertyHasVideo, kAudioBoxPropertyHasMIDI, kAudioBoxPropertyIsProtected,
        kAudioBoxPropertyAcquired, kAudioBoxPropertyAcquisitionFailed, kAudioBoxPropertyDeviceList,
        kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID, kAudioDevicePropertyTransportType,
        kAudioDevicePropertyRelatedDevices, kAudioDevicePropertyClockDomain,
        kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
        kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioDevicePropertyLatency, kAudioDevicePropertyStreams, kAudioObjectPropertyControlList,
        kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize,
        kAudioDevicePropertyBufferFrameSizeRange, kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyIcon,
        kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyPreferredChannelLayout,
        kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection, kAudioStreamPropertyTerminalType,
        kAudioStreamPropertyStartingChannel, kAudioStreamPropertyLatency,
        kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat,
        kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats,
        kAudioControlPropertyScope, kAudioControlPropertyElement, kAudioBooleanControlPropertyValue,
        kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue,
        kAudioLevelControlPropertyDecibelRange, kAudioLevelControlPropertyConvertScalarToDecibels,
        kAudioLevelControlPropertyConvertDecibelsToScalar
    };
    const AudioObjectPropertyScope scopes[] = {kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput};
    unsigned checks = 0;
    for (AudioObjectID object = kObjectID_PlugIn; object <= kObjectID_Mute_Output_Master; ++object) {
        for (size_t s = 0; s < sizeof(selectors) / sizeof(selectors[0]); ++s) {
            for (size_t scope = 0; scope < sizeof(scopes) / sizeof(scopes[0]); ++scope) {
                AudioObjectPropertyAddress a = address(selectors[s]);
                a.mScope = scopes[scope];
                if (!MacStereoFix_HasProperty(gAudioServerPlugInDriverRef, object, 0, &a)) continue;
                UInt32 size = 0;
                assert(MacStereoFix_GetPropertyDataSize(gAudioServerPlugInDriverRef, object, 0,
                    &a, 0, NULL, &size) == noErr);
                for (UInt32 capacity = 0; capacity <= size; ++capacity) {
                    void *data = calloc(1, capacity ? capacity : 1);
                    UInt32 written = UINT32_MAX;
                    OSStatus status = MacStereoFix_GetPropertyData(gAudioServerPlugInDriverRef,
                        object, 0, &a, 0, NULL, capacity, &written, data);
                    assert(written <= capacity);
                    if (capacity == size) assert(status == noErr && written == size);
                    if (status == noErr && written == sizeof(CFStringRef)) {
                        switch (selectors[s]) {
                            case kAudioObjectPropertyName: case kAudioObjectPropertyModelName:
                            case kAudioObjectPropertyManufacturer: case kAudioObjectPropertySerialNumber:
                            case kAudioObjectPropertyFirmwareVersion: case kAudioPlugInPropertyResourceBundle:
                            case kAudioBoxPropertyBoxUID: case kAudioDevicePropertyDeviceUID:
                            case kAudioDevicePropertyModelUID:
                                if (*(CFStringRef *)data) CFRelease(*(CFStringRef *)data);
                        }
                    }
                    free(data);
                    ++checks;
                }
            }
        }
    }
    printf("Driver property bounds: %u cases passed\n", checks);
}

static OSStatus io(UInt32 operation, double time, UInt32 frames, Float32 *data) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = cycle.mOutputTime.mSampleTime = time;
    return MacStereoFix_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device,
        operation == kAudioServerPlugInIOOperationWriteMix ? kObjectID_Stream_Output : kObjectID_Stream_Input,
        0, operation, frames, &cycle, data, NULL);
}

static void test_loopback(void) {
    Float32 written[32 * kChannelCount], read[32 * kChannelCount];
    for (unsigned i = 0; i < 32 * kChannelCount; ++i) written[i] = (Float32)i / 256;
    assert(io(kAudioServerPlugInIOOperationWriteMix, 4090, 32, written) == noErr);
    assert(io(kAudioServerPlugInIOOperationReadInput, 4090, 32, read) == noErr);
    assert(memcmp(written, read, sizeof(read)) == 0);
    assert(io(kAudioServerPlugInIOOperationReadInput, 4090 + kRingBufferFrameCount, 32, read) == noErr);
    for (unsigned i = 0; i < 32 * kChannelCount; ++i) assert(read[i] == 0);
    assert(io(kAudioServerPlugInIOOperationReadInput, -1, 32, read) == noErr);
    for (unsigned i = 0; i < 32 * kChannelCount; ++i) assert(read[i] == 0);
    const double invalid[] = {NAN, INFINITY, 0.5, 0x1p64};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        assert(io(kAudioServerPlugInIOOperationWriteMix, invalid[i], 32, written) != noErr);
        assert(io(kAudioServerPlugInIOOperationReadInput, invalid[i], 32, read) != noErr);
    }
    assert(io(kAudioServerPlugInIOOperationWriteMix, 0, kRingBufferFrameCount + 1, written) != noErr);
    puts("Loopback wrap, stale audio, invalid timestamps and frame limits passed");
}

static void test_formats_and_volume(void) {
    int number = 42;
    CFNumberRef invalidUID = CFNumberCreate(NULL, kCFNumberIntType, &number);
    AudioObjectID result;
    UInt32 resultSize;
    AudioObjectPropertyAddress lookup = address(kAudioPlugInPropertyTranslateUIDToDevice);
    assert(MacStereoFix_GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_PlugIn, 0,
        &lookup, sizeof(invalidUID), &invalidUID, sizeof(result), &resultSize, &result) == kAudioHardwareIllegalOperationError);
    CFRelease(invalidUID);
    AudioStreamBasicDescription fmt;
    UInt32 size = 0;
    assert(read_property(kObjectID_Stream_Output, kAudioStreamPropertyPhysicalFormat,
                         sizeof(fmt), &size, &fmt) == noErr);
    assert(set_property(kObjectID_Stream_Output, kAudioStreamPropertyPhysicalFormat,
                        sizeof(fmt), &fmt) == noErr);
    AudioStreamBasicDescription bad = fmt;
    bad.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    assert(set_property(kObjectID_Stream_Output, kAudioStreamPropertyPhysicalFormat,
                        sizeof(bad), &bad) == kAudioDeviceUnsupportedFormatError);
    bad = fmt; bad.mBytesPerFrame = 1;
    assert(set_property(kObjectID_Stream_Output, kAudioStreamPropertyPhysicalFormat,
                        sizeof(bad), &bad) == kAudioDeviceUnsupportedFormatError);
    bad = fmt; bad.mBitsPerChannel = 16;
    assert(set_property(kObjectID_Stream_Output, kAudioStreamPropertyPhysicalFormat,
                        sizeof(bad), &bad) == kAudioDeviceUnsupportedFormatError);
    Float32 invalid = NAN;
    assert(set_property(kObjectID_Volume_Output_Master, kAudioLevelControlPropertyScalarValue,
                        sizeof(invalid), &invalid) != noErr);
    invalid = INFINITY;
    assert(set_property(kObjectID_Volume_Output_Master, kAudioLevelControlPropertyDecibelValue,
                        sizeof(invalid), &invalid) != noErr);
    puts("Strict stream format and finite volume validation passed");
}

static _Atomic unsigned long long published_time;
static _Atomic bool writer_finished;
static void *concurrent_writer(void *unused) {
    (void)unused;
    Float32 frame[kChannelCount];
    for (UInt64 time = 100000; time < 300000; ++time) {
        for (unsigned c = 0; c < kChannelCount; ++c) frame[c] = (Float32)time;
        assert(io(kAudioServerPlugInIOOperationWriteMix, (double)time, 1, frame) == noErr);
        atomic_store(&published_time, time);
    }
    atomic_store(&writer_finished, true);
    return NULL;
}

static void test_concurrent_io(void) {
    pthread_t writer;
    assert(pthread_create(&writer, NULL, concurrent_writer, NULL) == 0);
    do {
        UInt64 time = atomic_load(&published_time);
        if (time == 0) continue;
        Float32 frame[kChannelCount];
        assert(io(kAudioServerPlugInIOOperationReadInput, (double)time, 1, frame) == noErr);
        // Under contention a frame may be silenced, but never contain a mix
        // of old/new channels or samples from another lap of the ring.
        assert(frame[0] == 0 || frame[0] == (Float32)time);
        for (unsigned c = 1; c < kChannelCount; ++c) assert(frame[c] == frame[0]);
    } while (!atomic_load(&writer_finished));
    assert(pthread_join(writer, NULL) == 0);
    puts("200,000 concurrent loopback writes passed");
}

static void test_clock_and_controls(void) {
    Float64 sampleTime;
    UInt64 hostTime, seed;
    UInt64 anchor = mach_absolute_time() - (UInt64)(gDevice_HostTicksPerFrame * kSampleRate * 5);
    atomic_store(&gDevice_AnchorHostTime, anchor);
    assert(MacStereoFix_GetZeroTimeStamp(gAudioServerPlugInDriverRef, kObjectID_Device, 0,
        &sampleTime, &hostTime, &seed) == noErr);
    assert(sampleTime >= kSampleRate * 4.9 && hostTime >= anchor);
    assert(MacStereoFix_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0) == noErr);
    assert(MacStereoFix_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0) == noErr);
    UInt64 nextSeed;
    assert(MacStereoFix_GetZeroTimeStamp(gAudioServerPlugInDriverRef, kObjectID_Device, 0,
        &sampleTime, &hostTime, &nextSeed) == noErr && nextSeed != seed);
    UInt32 value = 1, result = 0, size = 0;
    assert(set_property(kObjectID_Mute_Output_Master, kAudioBooleanControlPropertyValue,
        sizeof(value), &value) == noErr);
    assert(read_property(kObjectID_Mute_Output_Master, kAudioBooleanControlPropertyValue,
        sizeof(result), &size, &result) == noErr && result == 1);
    value = 0;
    assert(set_property(kObjectID_Stream_Input, kAudioStreamPropertyIsActive, sizeof(value), &value) == noErr);
    Float32 frame[kChannelCount] = {1, 1, 1, 1, 1, 1, 1, 1};
    assert(io(kAudioServerPlugInIOOperationWriteMix, 100, 1, frame) == noErr);
    assert(io(kAudioServerPlugInIOOperationReadInput, 100, 1, frame) == noErr);
    for (unsigned c = 0; c < kChannelCount; ++c) assert(frame[c] == 0);
    puts("Clock catch-up, restart seed, mute and inactive input passed");
}

int main(void) {
    assert(MacStereoFix_Initialize(gAudioServerPlugInDriverRef, NULL) == noErr);
    assert(MacStereoFix_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0) == noErr);
    test_property_bounds();
    test_loopback();
    test_formats_and_volume();
    test_concurrent_io();
    test_clock_and_controls();
    assert(MacStereoFix_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0) == noErr);
    return 0;
}
