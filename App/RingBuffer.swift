// RingBuffer.swift
//
// Single-producer / single-consumer interleaved Float32 ring buffer used to
// shuttle audio between the capture audio unit (writer) and the render audio
// unit (reader). Both run on real-time threads, so this code:
//   - never allocates after init
//   - never locks
//   - uses atomic indices with acquire/release ordering via MSFAtomic.h
//
// Capacity is in frames; each frame contains `channelCount` interleaved Float32
// samples. The usable capacity is (capacityFrames - 1) frames so that the
// empty/full conditions are distinguishable.

import Foundation

final class RingBuffer {

    // MARK: - Storage

    private let capacityFrames: Int
    private let channelCount: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writePtr: UnsafeMutablePointer<MSFAtomicU64>
    private let readPtr: UnsafeMutablePointer<MSFAtomicU64>

    // MARK: - Init / deinit

    init(frames: Int, channels: Int) {
        // Round up to power of two for cheap modulo via bitmask. Not strictly
        // required, but helps consistency with the driver's ring size.
        var p = 1
        while p < frames { p <<= 1 }
        self.capacityFrames = p
        self.channelCount = channels
        let totalSamples = p * channels
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        self.storage.initialize(repeating: 0, count: totalSamples)
        self.writePtr = UnsafeMutablePointer<MSFAtomicU64>.allocate(capacity: 1)
        self.readPtr  = UnsafeMutablePointer<MSFAtomicU64>.allocate(capacity: 1)
        msf_atomic_init(self.writePtr, 0)
        msf_atomic_init(self.readPtr, 0)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channelCount)
        storage.deallocate()
        writePtr.deallocate()
        readPtr.deallocate()
    }

    // MARK: - SPSC API

    /// Reset the buffer (only safe when neither side is running).
    func reset() {
        msf_atomic_store(writePtr, 0)
        msf_atomic_store(readPtr, 0)
    }

    /// Current number of frames available to read. Safe to call from the
    /// consumer side.
    func fillFrames() -> Int {
        let w = msf_atomic_load(writePtr)
        let r = msf_atomic_load(readPtr)
        return Int(w &- r)
    }

    /// Advance the read pointer by up to `frameCount` frames without reading
    /// them. Used by the consumer to drop oldest frames when the buffer has
    /// accumulated more latency than desired. Returns the number actually
    /// skipped.
    @discardableResult
    func skip(frameCount: Int) -> Int {
        let w = msf_atomic_load(writePtr)
        let r = msf_atomic_load(readPtr)
        let avail = Int(w &- r)
        if avail <= 0 || frameCount <= 0 { return 0 }
        let toSkip = min(frameCount, avail)
        msf_atomic_store(readPtr, r &+ UInt64(toSkip))
        return toSkip
    }

    /// Write up to `frameCount` frames from `src`. Returns frames written.
    /// Caller is the single producer.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, frameCount: Int) -> Int {
        let w = msf_atomic_load(writePtr)
        let r = msf_atomic_load(readPtr)
        let free = capacityFrames - 1 - Int(w &- r)
        if free <= 0 { return 0 }
        let toWrite = min(frameCount, free)
        let mask = UInt64(capacityFrames - 1)
        let writeIdx = Int(w & mask)
        let firstChunk = min(toWrite, capacityFrames - writeIdx)
        let secondChunk = toWrite - firstChunk
        // First chunk
        memcpy(storage.advanced(by: writeIdx * channelCount),
               src,
               firstChunk * channelCount * MemoryLayout<Float>.size)
        // Wrapped chunk
        if secondChunk > 0 {
            memcpy(storage,
                   src.advanced(by: firstChunk * channelCount),
                   secondChunk * channelCount * MemoryLayout<Float>.size)
        }
        msf_atomic_store(writePtr, w &+ UInt64(toWrite))
        return toWrite
    }

    /// Read up to `frameCount` frames into `dst`. Returns frames read.
    /// Caller is the single consumer.
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let w = msf_atomic_load(writePtr)
        let r = msf_atomic_load(readPtr)
        let avail = Int(w &- r)
        if avail <= 0 { return 0 }
        let toRead = min(frameCount, avail)
        let mask = UInt64(capacityFrames - 1)
        let readIdx = Int(r & mask)
        let firstChunk = min(toRead, capacityFrames - readIdx)
        let secondChunk = toRead - firstChunk
        memcpy(dst,
               storage.advanced(by: readIdx * channelCount),
               firstChunk * channelCount * MemoryLayout<Float>.size)
        if secondChunk > 0 {
            memcpy(dst.advanced(by: firstChunk * channelCount),
                   storage,
                   secondChunk * channelCount * MemoryLayout<Float>.size)
        }
        msf_atomic_store(readPtr, r &+ UInt64(toRead))
        return toRead
    }
}
