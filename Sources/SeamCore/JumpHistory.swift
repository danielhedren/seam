/// Where the reader was before each jump, for Go › Back and Forward (SPEC §7.4.1).
public struct JumpHistory: Equatable, Sendable {
    public static let limit = 100

    public private(set) var back: [ScrollAnchor] = []
    public private(set) var forward: [ScrollAnchor] = []

    public init() {}

    /// A jump is leaving `place`. Jumping again from the same place adds nothing.
    public mutating func record(_ place: ScrollAnchor) {
        forward = []
        guard back.last != place else { return }
        back.append(place)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
    }

    /// The place Back goes to from `current`, skipping files the diff no longer `has`.
    public mutating func goBack(from current: ScrollAnchor?, has: (String) -> Bool)
        -> ScrollAnchor?
    {
        Self.step(from: &back, to: &forward, current: current, has: has)
    }

    public mutating func goForward(from current: ScrollAnchor?, has: (String) -> Bool)
        -> ScrollAnchor?
    {
        Self.step(from: &forward, to: &back, current: current, has: has)
    }

    public func canGoBack(has: (String) -> Bool) -> Bool { back.contains { has($0.path) } }
    public func canGoForward(has: (String) -> Bool) -> Bool { forward.contains { has($0.path) } }

    private static func step(
        from: inout [ScrollAnchor], to: inout [ScrollAnchor], current: ScrollAnchor?,
        has: (String) -> Bool
    ) -> ScrollAnchor? {
        while let place = from.popLast() {
            guard has(place.path) else { continue }
            if let current { to.append(current) }
            return place
        }
        return nil
    }
}
