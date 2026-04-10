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
/// Frames of ring-buffer headroom between capture and render threads.
let kMSFRingFrames: Int = 16384

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
    private var pullScratchCapacity: Int = 0

    // MARK: Downmix gains

    /// Linear center-channel gain. Read on the real-time render thread, written
    /// from the UI thread — stored as an atomic float so there's no tearing.
    private let centerGain = UnsafeMutablePointer<MSFAtomicFloat>.allocate(capacity: 1)
    /// Surround / rear-surround coefficients are fixed ITU constants.
    private static let surroundGain: Float = 0.707  // -3 dB, ITU Ls/Rs
    private static let rearGain: Float = 0.5        // -6 dB, Lsr/Rsr

    // MARK: - Init / deinit

    init() {
        msf_atomic_float_init(centerGain, 0.707)
    }

    deinit {
        centerGain.deallocate()
    }

    // MARK: - Public API

    /// True once both audio units have been built and started.
    var isRunning: Bool { captureUnit != nil && renderUnit != nil }

    /// Set the dialogue boost in dB (added on top of the -3 dB ITU baseline).
    func setDialogueBoostDB(_ dB: Float) {
        let linear: Float = 0.707 * pow(10.0, dB / 20.0)
        msf_atomic_float_store(centerGain, linear)
    }

    // MARK: - Start / stop

    func start(outputDevice: AudioDeviceID) throws {
        guard !isRunning else { return }

        guard let macStereoFix = SystemAudio.macStereoFixDeviceID() else {
            throw RouterError.macStereoFixNotFound
        }

        ringBuffer.reset()

        try buildCaptureUnit(deviceID: macStereoFix)
        do {
            try buildRenderUnit(deviceID: outputDevice)
        } catch {
            tearDownCaptureUnit()
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
        if let c = captureUnit { AudioOutputUnitStop(c) }
        if let r = renderUnit  { AudioOutputUnitStop(r) }
        tearDown()
    }

    /// Swap only the render (output) device while capture stays running.
    /// This avoids toggling the system default device and eliminates the
    /// audible gap when the user switches output devices mid-session.
    func switchOutputDevice(_ newDeviceID: AudioDeviceID) throws {
        guard isRunning else { return }
        if let r = renderUnit { AudioOutputUnitStop(r) }
        tearDownRenderUnit()
        try buildRenderUnit(deviceID: newDeviceID)
        if let r = renderUnit {
            let status = AudioOutputUnitStart(r)
            if status != noErr {
                tearDownRenderUnit()
                throw RouterError.audioUnitError("AudioOutputUnitStart(render switch)", status)
            }
        }
    }

    // MARK: - Teardown

    private func tearDown() {
        tearDownCaptureUnit()
        tearDownRenderUnit()
    }

    private func tearDownCaptureUnit() {
        if let c = captureUnit {
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
            AudioUnitUninitialize(r)
            AudioComponentInstanceDispose(r)
            renderUnit = nil
        }
        if let p = pullScratch {
            p.deallocate()
            pullScratch = nil
            pullScratchCapacity = 0
        }
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

        // Query the device's maximum IO buffer size so we never under-allocate.
        // Fall back to a safe default if the query fails.
        var maxFrameSize: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        var bufSizeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &bufSizeAddr, 0, nil, &propSize, &maxFrameSize) != noErr || maxFrameSize == 0 {
            maxFrameSize = 4096
        }
        // Add headroom: some devices may deliver slightly more than reported.
        let maxFrames = Int(maxFrameSize) * 2
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

        // We provide stereo Float32 at 48k. The HALOutput unit will sample-rate
        // convert to whatever the device wants.
        var fmt = AudioStreamBasicDescription(
            mSampleRate: kMSFSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * MemoryLayout<Float>.size),
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

        var cb = AURenderCallbackStruct(
            inputProc: AudioRouter.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(u,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("SetRenderCallback", status)
        }

        // Query the output device's buffer size and add headroom for the
        // render-side 8ch pull scratch.
        var outBufSize: UInt32 = 0
        var obsPropSize = UInt32(MemoryLayout<UInt32>.size)
        var obsSizeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &obsSizeAddr, 0, nil, &obsPropSize, &outBufSize) != noErr || outBufSize == 0 {
            outBufSize = 4096
        }
        let maxFrames = Int(outBufSize) * 2
        let total = maxFrames * kMSFChannelCount
        pullScratch = UnsafeMutablePointer<Float>.allocate(capacity: total)
        pullScratchCapacity = maxFrames

        status = AudioUnitInitialize(u)
        if status != noErr {
            AudioComponentInstanceDispose(u)
            throw RouterError.audioUnitError("AudioUnitInitialize(render)", status)
        }
        renderUnit = u
    }

    // MARK: - Real-time callbacks (C-style)

    private static let captureCallback: AURenderCallback = {
        (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _) -> OSStatus in
        let router = Unmanaged<AudioRouter>.fromOpaque(inRefCon).takeUnretainedValue()
        guard let unit = router.captureUnit,
              let abl = router.captureBufferList else {
            return noErr
        }
        // Clamp to our buffer capacity — drop excess frames rather than overrun.
        let framesToCapture = min(Int(inNumberFrames), router.captureBufferCapacity)
        abl.pointee.mBuffers.mDataByteSize = UInt32(framesToCapture * kMSFChannelCount * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, UInt32(framesToCapture), abl)
        if status != noErr {
            return status
        }
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
        // Render unit's input format is interleaved stereo Float32 -> single buffer.
        guard abl.count >= 1 else { return noErr }
        let stereoBuf = abl[0]
        guard let stereoRaw = stereoBuf.mData else { return noErr }
        let dst = stereoRaw.assumingMemoryBound(to: Float.self)
        let frames = Int(inNumberFrames)

        // Pull 8ch frames from ring buffer into scratch.
        guard let scratch = router.pullScratch, router.pullScratchCapacity >= frames else {
            // No scratch -> output silence.
            memset(dst, 0, frames * 2 * MemoryLayout<Float>.size)
            return noErr
        }
        let read = router.ringBuffer.read(scratch, frameCount: frames)
        if read < frames {
            // Zero-fill the tail of scratch where we have no data.
            let tailStart = read * kMSFChannelCount
            let tailCount = (frames - read) * kMSFChannelCount
            memset(scratch.advanced(by: tailStart), 0, tailCount * MemoryLayout<Float>.size)
        }

        // Downmix 8ch interleaved -> stereo interleaved.
        // Channel order (matches driver's preferred layout):
        //   0: L  1: R  2: C  3: LFE  4: Ls  5: Rs  6: Lsr  7: Rsr
        let cgain = msf_atomic_float_load(router.centerGain)
        let sgain = AudioRouter.surroundGain
        let rgain = AudioRouter.rearGain
        var s = 0
        var d = 0
        for _ in 0..<frames {
            let l   = scratch[s + 0]
            let r   = scratch[s + 1]
            let c   = scratch[s + 2]
            // skip LFE
            let ls  = scratch[s + 4]
            let rs  = scratch[s + 5]
            let lsr = scratch[s + 6]
            let rsr = scratch[s + 7]
            let lo = min(max(l + cgain * c + sgain * ls + rgain * lsr, -1.0), 1.0)
            let ro = min(max(r + cgain * c + sgain * rs + rgain * rsr, -1.0), 1.0)
            dst[d + 0] = lo
            dst[d + 1] = ro
            s += kMSFChannelCount
            d += 2
        }
        return noErr
    }
}
