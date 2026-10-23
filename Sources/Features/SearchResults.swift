import AppKit
import GitKit
import SeamCore
import SwiftUI

/// Files or Search, at the start of the file list's header (SPEC §7.3.1).
struct NavigatorPicker: View {
    @Bindable var review: WorktreeReview

    var body: some View {
        HStack(spacing: 2) {
            button(
                .files, systemImage: "list.bullet.rectangle",
                help: CommandCatalog.help(
                    String(localized: "Files", bundle: .module), command: "filter-files"))
            button(
                .search, systemImage: "magnifyingglass",
                help: CommandCatalog.help(
                    String(localized: "Search in Review", bundle: .module), command: "search"))
        }
    }

    private func button(_ navigator: Navigator, systemImage: String, help: String) -> some View {
        Button {
            review.navigator = navigator
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(review.navigator == navigator ? Color.accentColor : .secondary)
                .frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// "23 matches in 5 files" in the header.
struct SearchSummary: View {
    let review: WorktreeReview

    var body: some View {
        if let result = review.searchResult {
            Text(verbatim: Self.text(result)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// A path counts once, however often the query is in it.
    static func text(_ result: ReviewSearch.Result) -> String {
        guard !result.files.isEmpty else { return String(localized: "No results", bundle: .module) }
        if result.isTruncated {
            return String(
                localized: "First \(ReviewSearch.limit.formatted()) matches", bundle: .module)
        }
        let matches = result.matchCount + result.files.count { !$0.pathRanges.isEmpty }
        return String(
            localized: "\(Counted.matches(matches)) in \(Counted.files(result.files.count))",
            bundle: .module)
    }
}

/// The search field and its results tree, in place of the filter and the file list.
struct SearchResults: View {
    let session: RepoSession
    @Bindable var review: WorktreeReview
    var fieldFocus: FocusState<Bool>.Binding
    @FocusState private var listFocused: Bool

    var body: some View {
        let rows = review.searchRows
        VStack(spacing: 0) {
            FilterField(
                text: $review.search.text, focus: fieldFocus,
                placeholder: String(localized: "Search", bundle: .module),
                help: String(localized: "Text in the diff's lines and paths", bundle: .module),
                clearHelp: String(localized: "Clear Search", bundle: .module)
            ) {
                SearchOption(
                    label: "Aa", isOn: $review.search.matchesCase,
                    help: String(localized: "Match Case", bundle: .module))
                SearchOption(
                    label: ".*", isOn: $review.search.isRegex,
                    help: String(localized: "Regular Expression", bundle: .module))
            } onLeave: {
                listFocused = true
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            List(selection: selection(rows)) {
                ForEach(rows) { row in
                    SearchRowView(row: row, review: review)
                        .tag(row.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if let path = path(of: row) {
                                FileContextMenu(path: path, session: session)
                            }
                        }
                }
            }
            .focused($listFocused)
            .overlay { emptyState }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if review.search.text.isEmpty {
            ContentUnavailableView(
                String(localized: "Search the Review", bundle: .module),
                systemImage: "magnifyingglass",
                description: Text(
                    "Finds text in the changed lines and file paths.", bundle: .module))
        } else if review.searchIsInvalid {
            ContentUnavailableView(
                String(localized: "Invalid regular expression", bundle: .module),
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(
                    "“\(review.appliedSearch.text)” doesn't compile.", bundle: .module))
        } else if review.searchResult?.files.isEmpty == true {
            ContentUnavailableView {
                Label(
                    String(localized: "No results", bundle: .module), systemImage: "magnifyingglass"
                )
            } description: {
                Text("Nothing in the diff matches “\(review.appliedSearch.text)”.", bundle: .module)
            } actions: {
                Button(String(localized: "Clear Search", bundle: .module)) {
                    review.search.text = ""
                }
            }
        }
    }

    private func selection(_ rows: [SearchRow]) -> Binding<String?> {
        Binding(
            get: { review.selectedSearchRow },
            set: { id in
                guard let row = rows.first(where: { $0.id == id }) else { return }
                review.pick(row, controller: session.diff)
            })
    }

    private func path(of row: SearchRow) -> String? {
        guard let result = review.searchResult, let files = review.diff?.files else { return nil }
        switch row.kind {
        case .heading: return nil
        case .file(let position, _), .line(let position, _):
            return files[result.files[position].index].diff.path
        }
    }
}

/// Match Case or Regular Expression, inside the search field.
private struct SearchOption: View {
    let label: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: label).font(.caption.monospaced().bold())
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : .secondary)
        .help(help)
    }
}

private struct SearchRowView: View {
    let row: SearchRow
    let review: WorktreeReview

    var body: some View {
        if let result = review.searchResult, let files = review.diff?.files {
            content(result, files).padding(.leading, Double(row.depth) * 12)
        }
    }

    @ViewBuilder
    private func content(_ result: ReviewSearch.Result, _ files: [ReviewFile]) -> some View {
        switch row.kind {
        case .heading:
            // Folders stay open, so they have no chevron; the indent lines them up with files.
            Text(row.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 18)
        case .file(let position, let isFolded):
            let found = result.files[position]
            let file = files[found.index]
            HStack(spacing: 6) {
                Button {
                    review.toggleFold(file.diff.path)
                } label: {
                    Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .opacity(found.lines.isEmpty ? 0 : 1)
                .disabled(found.lines.isEmpty)
                Text(String(file.diff.status.letter))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(FileRowView.color(file.diff.status))
                    .frame(width: 12)
                Text(
                    Self.highlighted(
                        row.name,
                        SearchSnippet.name(row.name, path: file.diff.path, found.pathRanges))
                )
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if found.lineMatchCount > 0 {
                    Text(verbatim: "\(found.lineMatchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .line(let position, let index):
            let line = result.files[position].lines[index]
            let snippet = SearchSnippet.make(line.text, line.ranges)
            HStack(spacing: 6) {
                Text(verbatim: Self.marker(line.kind))
                    .foregroundStyle(line.kind == .added ? .green : .red)
                    .frame(width: 8)
                Text(verbatim: "\(line.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(Self.highlighted(snippet.text, snippet.ranges))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 18)
        }
    }

    private static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    /// Matches in the system's find colour, with dark text, which that yellow needs in either
    /// appearance.
    static func highlighted(_ text: String, _ ranges: [Range<Int>]) -> AttributedString {
        var attributed = AttributedString(text)
        let characters = attributed.characters
        let count = characters.count
        for range in ranges where range.lowerBound < count {
            let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(
                characters.startIndex, offsetBy: min(range.upperBound, count))
            attributed[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
            attributed[lower..<upper].foregroundColor = .black
        }
        return attributed
    }
}
