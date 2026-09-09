// AudioRouter.swift
//
// Owns two HAL audio units:
//   - captureUnit: pulls 8-channel Float32 audio from the MacStereoFix
//                  virtual device and writes it into the ring buffer.
//   - renderUnit:  reads from the ring buffer, downmixes 8ch -> 2ch with the
//                  current dialogue boost, and renders to the user's chosen
//                  real output device.
//
// All real-time work happens in two C callbacks (captureCallback,
// renderCallback). They never allocate, never lock, and only touch the ring
// buffer plus a couple of atomically-stored parameters on `Unmanaged<self>`.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Module constants

/// Channels in the virtual device's stream (L, R, C, LFE, Ls, Rs, Lsr, Rsr).
let kMSFChannelCount: Int = 8
/// Sample rate of the virtual device. Must match the driver's kSampleRate.
let kMSFSampleRate: Float64 = 48000
/// Bounded storage for large hardware IO cycles and sample-rate conversion.
let kMSFRingFrames = 32768
let kMSFMaximumFrames: UInt32 = 8192
let kMSFMaximumSourceFrames = 16384
let kMSFMaxFillFrames = 4096

// MARK: - AudioRouter

final class AudioRouter: @unchecked Sendable {

    // MARK: Errors

    enum RouterError: Error, LocalizedError {
        case macStereoFixNotFound
        case componentNotFound
        case audioUnitError(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .macStereoFixNotFound:
                return "MacStereoFix virtual device not found. Install the driver first."
            case .componentNotFound:
                return "HALOutput audio component not found."
            case .audioUnitError(let what, let status):
                return "\(what) failed (OSStatus \(status))"
            }
        }
    }

    // MARK: Audio units

    private var captureUnit: AudioUnit?
    private var renderUnit: AudioUnit?
    private var converterUnit: AudioUnit?

    // MARK: Buffers

    /// Lock-free SPSC buffer between capture (producer) and render (consumer).
    private let ringBuffer = RingBuffer(frames: kMSFRingFrames, channels: kMSFChannelCount)

    /// AudioBufferList + backing Float storage used by the capture callback
    /// to pull 8-ch frames out of the capture unit.
    private var captureBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var captureBufferStorage: UnsafeMutablePointer<Float>?
    private var captureBufferCapacity: Int = 0

    /// Scratch used inside the render callback to pull 8-ch frames from the
    /// ring buffer before downmixing. Lives as long as the render unit.
    private var pullScratch: UnsafeMutablePointer<Float>?
    private var stereoScratch: UnsafeMutablePointer<Float>?
    private var pullScratchCapacity: Int = 0
    private var renderPrimed = false // consumer only; reset with IO stopped

    // MARK: Downmix gains

    /// Linear center-channel gain. Read on the real-time render thread, written
    /// from the UI thread — stored as an atomic float so there's no tearing.
    private let centerGain = UnsafeMutablePointer<MSFAtomicFloat>.allocate(capacity: 1)
    /// Software attenuation applied after the bounded stereo downmix.
    private let outputGain = UnsafeMutablePointer<MSFAtomicFloat>.allocate(capacity: 1)
    private let callbackFailure = UnsafeMutablePointer<MSFAtomicU64>.allocate(capacity: 1)
    private let captureCycles = UnsafeMutablePointer<MSFAtomicU64>.allocate(capacity: 1)
    private let renderCycles = UnsafeMutablePointer<MSFAtomicU64>.allocate(capacity: 1)
    private let bufferedFrames = UnsafeMutablePointer<MSFAtomicFloat>.allocate(capacity: 1)
    private(set) var outputSampleRate: Float64 = 0

    // MARK: - Init / deinit

    init() {
        msf_atomic_float_init(centerGain, 0.707)
        msf_atomic_float_init(outputGain, 1)
        msf_atomic_init(callbackFailure, 0)
        msf_atomic_init(captureCycles, 0)
        msf_atomic_init(renderCycles, 0)
        msf_atomic_float_init(bufferedFrames, Float(StereoMix.reserveFrames))
    }

    deinit {
        stop()
        centerGain.deallocate()
        outputGain.deallocate()
        callbackFailure.deallocate()
        captureCycles.deallocate()
        renderCycles.deallocate()
        bufferedFrames.deallocate()
    }

    // MARK: - Public API

    /// True once both audio units have been built and started.
    var isRunning: Bool { captureUnit != nil && renderUnit != nil }

    /// Set the dialogue boost in dB (added on top of the -3 dB ITU baseline).
    func setDialogueBoostDB(_ dB: Float) {
        let linear = StereoMix.centerGain(boostDB: dB)
        msf_atomic_float_store(centerGain, linear)
    }

    // MARK: - Start / stop

    func start(outputDevice: AudioDeviceID) throws {
        guard !isRunning else { return }

        guard let macStereoFix = SystemAudio.macStereoFixDeviceID() else {
            throw RouterError.macStereoFixNotFound
        }

        ringBuffer.reset()
        renderPrimed = false
        msf_atomic_float_store(bufferedFrames, Float(StereoMix.reserveFrames))
        msf_atomic_store(callbackFailure, 0)
        msf_atomic_store(captureCycles, 0)
        msf_atomic_store(renderCycles, 0)
        do {
            try buildCaptureUnit(deviceID: macStereoFix)
            try buildRenderUnit(deviceID: outputDevice)
        } catch {
            tearDown()
            throw error
        }

        // Start render first so it can pull silence until capture warms up.
        if let r = renderUnit {
            let status = AudioOutputUnitStart(r)
            if status != noErr {
                tearDown()
                throw RouterError.audioUnitError("AudioOutputUnitStart(render)", status)
            }
        }
        if let c = captureUnit {
            let status = AudioOutputUnitStart(c)
            if status != noErr {
                tearDown()
                throw RouterError.audioUnitError("AudioOutputUnitStart(capture)", status)
            }
        }
    }

    func stop() {
        tearDown()
    }

    /// Rebuild with both callbacks stopped before touching shared storage.
    func switchOutputDevice(_ newDeviceID: AudioDeviceID) throws {
        stop()
        try start(outputDevice: newDeviceID)
    }

    func setOutputVolume(_ volume: Float) {
        msf_atomic_float_store(outputGain, volume.isFinite ? min(max(volume, 0), 1) : 0)
    }

    var audioFailed: Bool { msf_atomic_load(callbackFailure) != 0 }
    func updateClockDrift() {
        guard let converterUnit else { return }
        let rate = StereoMix.clockRate(bufferedFrames: msf_atomic_float_load(bufferedFrames))
        if AudioUnitSetParameter(converterUnit, kVarispeedParam_PlaybackRate,
            kAudioUnitScope_Global, 0, rate, 0) != noErr {
            msf_atomic_store(callbackFailure, 1)
        }
    }
    var progress: (capture: UInt64, render: UInt64) {
        (msf_atomic_load(captureCycles), msf_atomic_load(renderCycles))
    }

    // MARK: - Teardown

    private func tearDown() {
        tearDownCaptureUnit()
        tearDownRenderUnit()
    }

    private func tearDownCaptureUnit() {
        if let c = captureUnit {
            AudioOutputUnitStop(c)
            AudioUnitUninitialize(c)
            AudioComponentInstanceDispose(c)
            captureUnit = nil
        }
        if let bl = captureBufferList {
            bl.deallocate()
            captureBufferList = nil
        }
        if let s = captureBufferStorage {
            s.deallocate()
            captureBufferStorage = nil
            captureBufferCapacity = 0
        }
    }

    private func tearDownRenderUnit() {
        if let r = renderUnit {
            AudioOutputUnitStop(r)
            AudioUnitUninitialize(r)
            AudioComponentInstanceDispose(r)
            renderUnit = nil
        }
        if let c = converterUnit {
            AudioUnitUninitialize(c)
            AudioComponentInstanceDispose(c)
            converterUnit = nil
        }
        if let p = pullScratch {
            p.deallocate()
            pullScratch = nil
            pullScratchCapacity = 0
        }
        stereoScratch?.deallocate()
        stereoScratch = nil
    }

    // MARK: - Capture unit

    private func buildCaptureUnit(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw RouterError.componentNotFound
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &unit)
        if status != noErr || unit == nil {
            throw RouterError.audioUnitError("AudioComponentInstanceNew(capture)", status)
        }
        let u = unit!

        // Enable input on bus 1, disable output on bus 0.
        var enable: UInt32 = 1
        status = AudioUnitSetProperty(u,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("EnableIO(input)", status)
        }
        var disable: UInt32 = 0
        status = AudioUnitSetProperty(u,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("EnableIO(output disable)", status)
        }

        // Bind to the MacStereoFix device.
        var dev = deviceID
        status = AudioUnitSetProperty(u,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("CurrentDevice(capture)", status)
        }

        // We want 8ch interleaved Float32 at 48k coming out of the input bus.
        var fmt = AudioStreamBasicDescription(
            mSampleRate: kMSFSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(kMSFChannelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(kMSFChannelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(kMSFChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        status = AudioUnitSetProperty(u,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("StreamFormat(capture out)", status)
        }

        // Install the input callback.
        var cb = AURenderCallbackStruct(
            inputProc: AudioRouter.captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(u,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("SetInputCallback", status)
        }

        var maximum = kMSFMaximumFrames
        status = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maximum, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("MaximumFrames(capture)", status)
        }
        let maxFrames = Int(maximum)
        let totalSamples = maxFrames * kMSFChannelCount
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        abl.pointee.mNumberBuffers = 1
        abl.pointee.mBuffers.mNumberChannels = UInt32(kMSFChannelCount)
        abl.pointee.mBuffers.mDataByteSize = UInt32(totalSamples * MemoryLayout<Float>.size)
        abl.pointee.mBuffers.mData = UnsafeMutableRawPointer(storage)
        captureBufferList = abl
        captureBufferStorage = storage
        captureBufferCapacity = maxFrames

        status = AudioUnitInitialize(u)
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("AudioUnitInitialize(capture)", status)
        }
        captureUnit = u
    }

    // MARK: - Render unit

    private func buildRenderUnit(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw RouterError.componentNotFound
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &unit)
        if status != noErr || unit == nil {
            throw RouterError.audioUnitError("AudioComponentInstanceNew(render)", status)
        }
        let u = unit!

        // Output is enabled by default for HALOutput. Bind device.
        var dev = deviceID
        status = AudioUnitSetProperty(u,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("CurrentDevice(render)", status)
        }

        // AUHAL requires the hardware's sample rate. A separate Apple converter
        // supplies stereo at that rate without changing the user's device format.
        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &hardwareFormat, &formatSize)
        guard status == noErr, hardwareFormat.mSampleRate.isFinite,
              (32000...192000).contains(hardwareFormat.mSampleRate),
              hardwareFormat.mChannelsPerFrame >= 2 else {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("Select a stereo output at 32–192 kHz", status == noErr ? kAudioDeviceUnsupportedFormatError : status)
        }
        outputSampleRate = hardwareFormat.mSampleRate
        var fmt = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        status = AudioUnitSetProperty(u,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("StreamFormat(render in)", status)
        }

        do {
            let converter = try buildConverter(outputFormat: fmt)
            var connection = AudioUnitConnection(sourceAudioUnit: converter, sourceOutputNumber: 0, destInputNumber: 0)
            var maximum = kMSFMaximumFrames
            try check("Output frame limit", AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximum, UInt32(MemoryLayout<UInt32>.size)))
            try check("Connect converter", AudioUnitSetProperty(u, kAudioUnitProperty_MakeConnection,
                kAudioUnitScope_Input, 0, &connection, UInt32(MemoryLayout<AudioUnitConnection>.size)))
            try check("Initialize render", AudioUnitInitialize(u))
        } catch {
            AudioComponentInstanceDispose(u)
            throw error
        }
        renderUnit = u
    }

    private func check(_ operation: String, _ status: OSStatus) throws {
        if status != noErr { throw RouterError.audioUnitError(operation, status) }
    }

    private func buildConverter(outputFormat: AudioStreamBasicDescription) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_Varispeed,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw RouterError.componentNotFound }
        var unit: AudioUnit?
        try check("Create converter", AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw RouterError.componentNotFound }
        converterUnit = unit
        var format = outputFormat
        var source = format
        source.mSampleRate = kMSFSampleRate
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var callback = AURenderCallbackStruct(inputProc: AudioRouter.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var maximum = UInt32(kMSFMaximumSourceFrames)
        try check("Converter input", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &source, formatSize))
        try check("Converter output", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &format, formatSize))
        try check("Converter callback", AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check("Converter frame limit", AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maximum, UInt32(MemoryLayout<UInt32>.size)))
        pullScratch = UnsafeMutablePointer<Float>.allocate(capacity: kMSFMaximumSourceFrames * kMSFChannelCount)
        stereoScratch = UnsafeMutablePointer<Float>.allocate(capacity: kMSFMaximumSourceFrames * 2)
        pullScratchCapacity = kMSFMaximumSourceFrames
        try check("Initialize converter", AudioUnitInitialize(unit))
        return unit
    }

    #if MSF_TESTING
    // Exercise the production converter and callback without installing a driver
    // or sending any audio to hardware. This code is absent from app builds.
    func prepareOfflineOutput(sampleRate: Float64) throws -> AudioUnit {
        stop()
        ringBuffer.reset()
        renderPrimed = false
        return try buildConverter(outputFormat: AudioStreamBasicDescription(mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
    }
    func enqueueOfflineAudio(_ source: UnsafePointer<Float>, frames: Int) { ringBuffer.write(source, frameCount: frames) }
    #endif

    // MARK: - Real-time callbacks (C-style)

    private static let captureCallback: AURenderCallback = {
        (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _) -> OSStatus in
        let router = Unmanaged<AudioRouter>.fromOpaque(inRefCon).takeUnretainedValue()
        guard let unit = router.captureUnit,
              let abl = router.captureBufferList else {
            return noErr
        }
        let framesToCapture = Int(inNumberFrames)
        guard framesToCapture <= router.captureBufferCapacity else {
            msf_atomic_store(router.callbackFailure, 1)
            return kAudioUnitErr_TooManyFramesToProcess
        }
        abl.pointee.mBuffers.mDataByteSize = UInt32(framesToCapture * kMSFChannelCount * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, UInt32(framesToCapture), abl)
        if status != noErr {
            msf_atomic_store(router.callbackFailure, 1)
            return status
        }
        guard abl.pointee.mNumberBuffers == 1, abl.pointee.mBuffers.mNumberChannels == UInt32(kMSFChannelCount),
              abl.pointee.mBuffers.mData != nil,
              Int(abl.pointee.mBuffers.mDataByteSize) >= framesToCapture * kMSFChannelCount * MemoryLayout<Float>.size else {
            msf_atomic_store(router.callbackFailure, 1)
            return kAudioUnitErr_FormatNotSupported
        }
        msf_atomic_store(router.captureCycles, msf_atomic_load(router.captureCycles) &+ 1)
        // Push captured 8ch frames into the ring buffer (drop on overflow).
        if let raw = abl.pointee.mBuffers.mData {
            let src = raw.assumingMemoryBound(to: Float.self)
            _ = router.ringBuffer.write(src, frameCount: framesToCapture)
        }
        return noErr
    }

    private static let renderCallback: AURenderCallback = {
        (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
        let router = Unmanaged<AudioRouter>.fromOpaque(inRefCon).takeUnretainedValue()
        guard let ioData = ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(inNumberFrames)
        let bytes = frames * MemoryLayout<Float>.size
        // AUVarispeed uses planar Float32. Provide preallocated storage whenever
        // the converter leaves a channel pointer nil, and validate every plane.
        guard abl.count == 2, frames <= router.pullScratchCapacity,
              let scratch = router.pullScratch, let stereo = router.stereoScratch else {
            for buffer in abl { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            msf_atomic_store(router.callbackFailure, 1)
            return kAudioUnitErr_TooManyFramesToProcess
        }
        for channel in 0..<2 {
            if abl[channel].mData == nil {
                abl[channel].mData = UnsafeMutableRawPointer(stereo.advanced(by: channel * router.pullScratchCapacity))
                abl[channel].mDataByteSize = UInt32(bytes)
            }
            guard abl[channel].mNumberChannels == 1, Int(abl[channel].mDataByteSize) >= bytes else {
                for buffer in abl { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                msf_atomic_store(router.callbackFailure, 1)
                return kAudioUnitErr_FormatNotSupported
            }
        }
        let left = abl[0].mData!.assumingMemoryBound(to: Float.self)
        let right = abl[1].mData!.assumingMemoryBound(to: Float.self)

        // Cap app-side latency: if the capture side has gotten ahead of us
        // by more than kMSFMaxFillFrames + this cycle's frames, discard the
        // excess oldest frames before reading. Without this the steady-state
        // fill is whatever the startup race between capture and render
        // produced, which just sits in the pipe forever as pure delay.
        let targetFill = kMSFMaxFillFrames + frames
        let currentFill = router.ringBuffer.fillFrames()
        if !router.renderPrimed {
            guard currentFill >= frames + StereoMix.reserveFrames else {
                memset(left, 0, bytes)
                memset(right, 0, bytes)
                return noErr
            }
            router.renderPrimed = true
        }
        if currentFill > targetFill {
            router.ringBuffer.skip(frameCount: currentFill - targetFill)
        }
        let read = router.ringBuffer.read(scratch, frameCount: frames)
        let fill = Float(router.ringBuffer.fillFrames())
        let previous = msf_atomic_float_load(router.bufferedFrames)
        msf_atomic_float_store(router.bufferedFrames, previous + 0.01 * (fill - previous))
        if read < frames {
            router.renderPrimed = false
            // Zero-fill the tail of scratch where we have no data.
            let tailStart = read * kMSFChannelCount
            let tailCount = (frames - read) * kMSFChannelCount
            memset(scratch.advanced(by: tailStart), 0, tailCount * MemoryLayout<Float>.size)
        }

        StereoMix.process(scratch, into: left, right: right, frames: frames,
            centerGain: msf_atomic_float_load(router.centerGain),
            volume: msf_atomic_float_load(router.outputGain))
        msf_atomic_store(router.renderCycles, msf_atomic_load(router.renderCycles) &+ 1)
        return noErr
    }
}
