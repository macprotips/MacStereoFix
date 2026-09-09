import AudioToolbox
import CoreAudio
import Foundation

@main
struct AudioTests {
    static func main() throws {
        testDownmix()
        testRing()
        testConcurrentRing()
        try testConverter()
        testClockDrift()
    }

    static func testClockDrift() {
        // Model an output clock +/-500 ppm from the virtual clock for 30 minutes,
        // with the same once-per-second correction used by the app.
        for ppm: Float in [-500, -100, 0, 100, 500] {
            var fill = Float(StereoMix.reserveFrames)
            for _ in 0..<1800 {
                let ratio = StereoMix.clockRate(bufferedFrames: fill)
                fill += 48000 - 48000 * (1 + ppm / 1_000_000) * ratio
                assert(fill > 128 && fill < 1024)
            }
        }
        assert(StereoMix.clockRate(bufferedFrames: .nan) == 1)
        print("Clock correction simulation stayed bounded for 30 minutes at +/-500 ppm")
    }

    static func testDownmix() {
        let expected: [(Float, Float)] = [(0.25, 0), (0, 0.25), (0.17675, 0.17675), (0, 0),
                                         (0.17675, 0), (0, 0.17675), (0.125, 0), (0, 0.125)]
        for channel in 0..<8 {
            var source = [Float](repeating: 0, count: 8)
            source[channel] = 0.25
            var output = [Float](repeating: 0, count: 2)
            StereoMix.process(source, into: &output, frames: 1, centerGain: 0.707, volume: 1)
            assert(abs(output[0] - expected[channel].0) < 0.00001)
            assert(abs(output[1] - expected[channel].1) < 0.00001)
        }
        for bad: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            let source = [Float](repeating: bad, count: 8)
            for volume: Float in [0, 0.5, 1, .nan, .infinity] {
                var output = [Float](repeating: 99, count: 2)
                StereoMix.process(source, into: &output, frames: 1, centerGain: .infinity, volume: volume)
                assert(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
                if volume == 0 { assert(output == [0, 0]) }
            }
        }
        assert(StereoMix.centerGain(boostDB: .nan).isFinite)
        assert(StereoMix.centerGain(boostDB: 100) == StereoMix.centerGain(boostDB: 9))
        var muted = [Float](repeating: 1, count: 2)
        StereoMix.process([Float](repeating: 1, count: 8), into: &muted, frames: 1, centerGain: 2, volume: 0)
        assert(muted == [0, 0])
        print("Eight channel impulses, LFE exclusion, gain limits, mute and non-finite samples passed")
    }

    static func testRing() {
        let ring = RingBuffer(frames: 8, channels: 2)
        let source = (0..<32).map(Float.init)
        var output = [Float](repeating: -1, count: 32)
        assert(ring.write(source, frameCount: -1) == 0)
        assert(ring.read(&output, frameCount: -1) == 0)
        assert(ring.write(source, frameCount: 16) == 7)
        assert(ring.fillFrames() == 7)
        assert(ring.read(&output, frameCount: 5) == 5)
        assert(Array(output.prefix(10)) == Array(source.prefix(10)))
        assert(ring.write(source, frameCount: 5) == 5)
        assert(ring.read(&output, frameCount: 7) == 7)
        assert(Array(output.prefix(14)) == Array(source[10..<14]) + Array(source.prefix(10)))
        assert(ring.read(&output, frameCount: 1) == 0)
        assert(ring.skip(frameCount: 20) == 0)
        ring.write(source, frameCount: 4)
        assert(ring.skip(frameCount: 10) == 4)
        ring.reset()
        assert(ring.fillFrames() == 0)
        print("Ring overflow, underflow, wrap, skip, reset and negative lengths passed")
    }

    static func testConcurrentRing() {
        let ring = RingBuffer(frames: 1024, channels: 2)
        let group = DispatchGroup()
        let frames = 200_000
        group.enter()
        DispatchQueue.global().async {
            var position = 0
            while position < frames {
                let count = min(37, frames - position)
                var source = [Float](repeating: 0, count: count * 2)
                for i in 0..<count {
                    source[2*i] = Float(position + i)
                    source[2*i+1] = -Float(position + i)
                }
                position += ring.write(source, frameCount: count)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            var position = 0
            var output = [Float](repeating: 0, count: 106)
            while position < frames {
                let read = ring.read(&output, frameCount: 53)
                for i in 0..<read {
                    assert(output[2*i] == Float(position + i))
                    assert(output[2*i+1] == -Float(position + i))
                }
                position += read
            }
            group.leave()
        }
        assert(group.wait(timeout: .now() + 20) == .success)
        print("200,000 concurrent SPSC frames passed")
    }

    static func testConverter() throws {
        let router = AudioRouter()
        router.setDialogueBoostDB(0)
        router.setOutputVolume(0.5)
        var source = [Float](repeating: 0, count: 4096 * 8)
        for frame in 0..<4096 { source[frame * 8 + 2] = 0.25 }
        for rate: Float64 in [32000, 44100, 48000, 96000, 192000] {
            let unit = try router.prepareOfflineOutput(sampleRate: rate)
            router.enqueueOfflineAudio(source, frames: 4096)
            var output = [Float](repeating: 99, count: 512 * 2)
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            var flags = AudioUnitRenderActionFlags()
            for cycle in 0..<3 {
                timestamp.mSampleTime = Float64(cycle * 512)
                let status = output.withUnsafeMutableBytes { bytes -> OSStatus in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count / 2), mData: bytes.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count / 2), mData: bytes.baseAddress!.advanced(by: bytes.count / 2))
                return AudioUnitRender(unit, &flags, &timestamp, 0, 512, list.unsafeMutablePointer)
                }
                assert(status == noErr, "Converter failed at \(rate): \(status)")
            }
            assert(output.allSatisfy { $0.isFinite && abs($0) <= 0.11 })
            assert(output.filter { abs($0 - 0.088375) < 0.0001 }.count > 700,
                   "Center channel missing after conversion at \(rate)")
            assert(!router.audioFailed)
            router.stop()
        }
        print("Production audio callback and Apple converter passed at 32, 44.1, 48, 96 and 192 kHz (offline)")
    }
}
