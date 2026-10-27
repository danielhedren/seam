import SeamCore

/// Where the diff scrolls when it shows new content.
public enum DiffPosition: Equatable, Sendable {
    /// Keep the reader on the same file and line across a reload (SPEC §8.6).
    case keep
    case top
    case anchor(ScrollAnchor)
    case file(String)
    /// A thread's card, with the lines it's on above it.
    case thread(String)
}
