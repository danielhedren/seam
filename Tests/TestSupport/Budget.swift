import Foundation

/// A SPEC §8.7 budget as this machine is held to it. The budgets are measured on a real Mac; a
/// shared CI runner is about twice as slow, so it sets `SEAM_BENCH_SLACK` and still fails on a
/// real regression.
public func budget(_ duration: Duration) -> Duration {
    let slack = ProcessInfo.processInfo.environment["SEAM_BENCH_SLACK"].flatMap(Double.init) ?? 1
    return duration * slack
}
