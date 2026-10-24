import Testing

@testable import SeamCore

/// SPEC §7.3: which files the diff folds.
@Suite(.timeLimit(.minutes(1)))
struct CollapseRulesTests {
    private func file(
        _ path: String, generated: Bool = false, _ status: ViewedMarks.Status = .unviewed
    ) -> CollapseState.File {
        CollapseState.File(path: path, startsCollapsed: generated, status: status)
    }

    @Test func generatedFilesStartCollapsedUntilTheReaderOpensThem() {
        var state = CollapseState()
        state.load(
            [file("a.swift"), file("gen.pb.swift", generated: true)], collapsesViewed: false)
        #expect(state.collapsed == ["gen.pb.swift"])
        state.toggle("gen.pb.swift")
        state.load(
            [file("a.swift"), file("gen.pb.swift", generated: true)], collapsesViewed: false)
        #expect(state.collapsed.isEmpty, "the reader's opening survives a reload")
    }

    @Test func aViewedFileFoldsAwayAndOpensOnceWhenItChanges() {
        var state = CollapseState()
        state.load([file("a.swift")], collapsesViewed: true)
        state.viewedChanged("a.swift", to: .viewed, collapsesViewed: true)
        #expect(state.collapsed == ["a.swift"])

        state.load([file("a.swift", .changedSinceViewed)], collapsesViewed: true)
        #expect(state.collapsed.isEmpty, "a change opens it")
        state.toggle("a.swift")
        state.load([file("a.swift", .changedSinceViewed)], collapsesViewed: true)
        #expect(state.collapsed == ["a.swift"], "only once: the reader's collapse sticks")
    }

    @Test func withTheSettingOffViewingFoldsNothing() {
        var state = CollapseState()
        state.load([file("a.swift", .viewed)], collapsesViewed: false)
        state.viewedChanged("a.swift", to: .viewed, collapsesViewed: false)
        #expect(state.collapsed.isEmpty)
    }

    @Test func unmarkingAViewedFileOpensIt() {
        var state = CollapseState()
        state.load([file("a.swift", .viewed)], collapsesViewed: true)
        #expect(state.collapsed == ["a.swift"])
        state.viewedChanged("a.swift", to: .unviewed, collapsesViewed: true)
        #expect(state.collapsed.isEmpty)
    }
}
