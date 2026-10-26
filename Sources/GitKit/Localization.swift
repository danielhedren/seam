// Linux has neither String Catalogs nor `String(localized:)`. Seam's strings are English only,
// so there the key with its values filled in is the text, and call sites compile unchanged
// (ADR 0007). macOS keeps Foundation's, which Xcode extracts the catalogs' keys from.
#if !canImport(Darwin)
    import Foundation

    extension String {
        public struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
            public struct StringInterpolation: StringInterpolationProtocol {
                var text = ""

                public init(literalCapacity: Int, interpolationCount: Int) {}
                public mutating func appendLiteral(_ literal: String) { text += literal }
                public mutating func appendInterpolation<T>(_ value: T) { text += "\(value)" }
            }

            let text: String

            public init(stringLiteral value: String) { text = value }
            public init(stringInterpolation: StringInterpolation) {
                text = stringInterpolation.text
            }
        }

        public init(localized value: LocalizationValue, bundle: Bundle? = nil) {
            self = value.text
        }
    }
#endif
