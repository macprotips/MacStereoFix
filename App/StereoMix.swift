import Foundation

enum StereoMix {
    static let reserveFrames = 512

    /// Independent audio clocks drift. Keep a small reserve using Apple's
    /// varispeed converter, with at most 0.1% correction (under two cents).
    static func clockRate(bufferedFrames: Float) -> Float {
        guard bufferedFrames.isFinite else { return 1 }
        return 1 + min(max((bufferedFrames - Float(reserveFrames)) * 0.000002, -0.001), 0.001)
    }

    static func centerGain(boostDB: Float) -> Float {
        let boost = boostDB.isFinite ? min(max(boostDB, 0), 9) : 0
        return 0.707 * pow(10, boost / 20)
    }

    /// L, R, C, LFE, Ls, Rs, Lsr, Rsr -> L, R. No allocation on the audio thread.
    static func process(_ source: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>? = nil, frames: Int, centerGain: Float, volume: Float) {
        guard frames > 0 else { return }
        let stride = right == nil ? 2 : 1
        let rightOutput = right ?? output.advanced(by: 1)
        let gain = volume.isFinite ? min(max(volume, 0), 1) : 0
        let center = centerGain.isFinite ? min(max(centerGain, 0), 2) : 0
        for frame in 0..<frames {
            let s = source.advanced(by: frame * 8)
            // Sanitize each source before summing; a bad sample cannot poison the converter.
            let c = finite(s[2]) * center
            let left = finite(s[0]) + c + 0.707 * finite(s[4]) + 0.5 * finite(s[6])
            let right = finite(s[1]) + c + 0.707 * finite(s[5]) + 0.5 * finite(s[7])
            output[frame * stride] = min(max(left, -1), 1) * gain
            rightOutput[frame * stride] = min(max(right, -1), 1) * gain
        }
    }

    private static func finite(_ sample: Float) -> Float {
        sample.isFinite ? min(max(sample, -1), 1) : 0
    }
}
