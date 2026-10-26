// Seam's logging (ADR 0007): `os` on Apple platforms, and on Linux look-alikes that accept the
// same calls and stay quiet, so call sites compile unchanged on both.
#if canImport(os)
    import os

    public typealias Logger = os.Logger
    public typealias OSSignposter = os.OSSignposter
#else
    public struct OSLogPrivacy: Sendable {
        public static let `public` = OSLogPrivacy()
        public static let `private` = OSLogPrivacy()
        public static let auto = OSLogPrivacy()
    }

    public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
        public struct StringInterpolation: StringInterpolationProtocol {
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) {}
            public mutating func appendInterpolation<T>(
                _ value: @autoclosure () -> T, privacy: OSLogPrivacy = .auto
            ) {}
        }

        public init(stringLiteral value: String) {}
        public init(stringInterpolation: StringInterpolation) {}
    }

    public struct Logger: Sendable {
        public init(subsystem: String, category: String) {}
        public func debug(_ message: OSLogMessage) {}
        public func info(_ message: OSLogMessage) {}
        public func error(_ message: OSLogMessage) {}
    }

    public struct OSSignposter: Sendable {
        public struct IntervalState: Sendable {}

        public init(subsystem: String, category: String) {}
        public func beginInterval(_ name: StaticString, _ message: OSLogMessage = "")
            -> IntervalState
        { IntervalState() }
        public func endInterval(_ name: StaticString, _ state: IntervalState) {}
    }
#endif
