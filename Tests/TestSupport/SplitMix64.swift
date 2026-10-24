import Foundation

/// A seeded random generator, so a property test that fails can be replayed with its seed
/// (`SEAM_SEED`).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The seed from `SEAM_SEED`, else a random one to print on failure.
    public static func seed() -> UInt64 {
        UInt64(ProcessInfo.processInfo.environment["SEAM_SEED"] ?? "")
            ?? UInt64.random(in: 1...UInt64.max)
    }
}
