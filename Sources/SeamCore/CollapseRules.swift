import Foundation

/// Which files the diff shows folded (SPEC §7.3): generated and large ones start collapsed, and
/// with Collapse Viewed Files on, a viewed file folds away and opens again once it changes. The
/// reader's own toggles win until a change reopens the file. Pure, so the rules are tested as a
/// table.
public struct CollapseState: Equatable, Sendable {
    public private(set) var collapsed: Set<String> = []
    /// Files the reader opened that would otherwise start collapsed.
    private var openedByReader: Set<String> = []
    /// Each file's viewed status at the last load, to see a viewed file change.
    private var lastStatuses: [String: ViewedMarks.Status] = [:]

    public init() {}

    public struct File: Sendable {
        public var path: String
        public var startsCollapsed: Bool
        public var status: ViewedMarks.Status

        public init(path: String, startsCollapsed: Bool, status: ViewedMarks.Status) {
            self.path = path
            self.startsCollapsed = startsCollapsed
            self.status = status
        }
    }

    /// A newly loaded diff.
    public mutating func load(_ files: [File], collapsesViewed: Bool) {
        var statuses: [String: ViewedMarks.Status] = [:]
        for file in files {
            statuses[file.path] = file.status
            // Opens once, when a viewed file changes, so a reader's later collapse sticks.
            if collapsesViewed, file.status == .changedSinceViewed,
                lastStatuses[file.path] == .viewed, !file.startsCollapsed
            {
                collapsed.remove(file.path)
            } else if file.startsCollapsed || (collapsesViewed && file.status == .viewed),
                !openedByReader.contains(file.path)
            {
                collapsed.insert(file.path)
            }
        }
        lastStatuses = statuses
    }

    /// A file marked viewed or not: with the setting on, it folds away or opens again.
    public mutating func viewedChanged(
        _ path: String, to status: ViewedMarks.Status,
        collapsesViewed: Bool
    ) {
        lastStatuses[path] = status
        guard collapsesViewed else { return }
        if status == .viewed {
            collapsed.insert(path)
            openedByReader.remove(path)
        } else {
            collapsed.remove(path)
        }
    }

    public mutating func toggle(_ path: String) {
        if collapsed.remove(path) == nil {
            collapsed.insert(path)
            openedByReader.remove(path)
        } else {
            openedByReader.insert(path)
        }
    }
}
