import GitKit
import SeamCore
import SwiftUI

struct FileList: View {
    let session: RepoSession
    @Bindable var review: WorktreeReview
    var filterFocus: FocusState<Bool>.Binding
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavigatorPicker(review: review)
                switch review.navigator {
                case .files: totals
                case .search: SearchSummary(review: review)
                }
                Spacer()
                Toggle(isOn: $review.flatFileList) {
                    Image(systemName: "list.bullet.indent")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(
                    review.flatFileList
                        ? String(localized: "Show as Tree", bundle: .module)
                        : String(localized: "Show as Flat List", bundle: .module))
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 10)
            .frame(height: PaneHeader.height(session) - 1)
            Divider()
            switch review.navigator {
            case .files: files
            case .search:
                SearchResults(session: session, review: review, fieldFocus: filterFocus)
            }
        }
    }

    @ViewBuilder private var totals: some View {
        if let diff = review.diff {
            Text(verbatim: Counted.files(diff.files.count))
            if !diff.files.isEmpty {
                Text(verbatim: "+\(diff.additions)").foregroundStyle(.green)
                Text(verbatim: "−\(diff.deletions)").foregroundStyle(.red)
                ViewedProgress(viewed: review.viewed.viewedCount(in: diff), of: diff.files.count)
            }
        }
    }

    @ViewBuilder private var files: some View {
        let files = review.diff?.files ?? []
        let rows = review.fileListRows
        VStack(spacing: 0) {
            FilterField(text: $review.fileFilter, focus: filterFocus) { listFocused = true }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            List(selection: selection(files, rows)) {
                ForEach(rows) { row in
                    FileRowView(row: row, files: files, viewed: status(row, files)) {
                        toggle(row)
                    }
                    .tag(row.id)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if case .file(let index) = row.kind {
                            FileContextMenu(path: files[index].diff.path, session: session)
                        }
                    }
                }
            }
            .focused($listFocused)
            .overlay {
                if rows.isEmpty && !review.fileFilter.isEmpty {
                    ContentUnavailableView {
                        Label(
                            String(localized: "No matching files", bundle: .module),
                            systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(
                            "No changed file's path matches “\(review.fileFilter)”.",
                            bundle: .module)
                    } actions: {
                        Button(String(localized: "Clear Filter", bundle: .module)) {
                            review.fileFilter = ""
                        }
                    }
                }
            }
        }
    }

    /// The list follows the diff's scroll position; picking a row scrolls the diff to it.
    private func selection(_ files: [ReviewFile], _ rows: [FileListRow]) -> Binding<String?> {
        Binding(
            get: { review.currentFile },
            set: { id in
                guard let row = rows.first(where: { $0.id == id }), case .file(let index) = row.kind
                else { return }
                let path = files[index].diff.path
                review.currentFile = path
                session.diff.scroll(toFile: path)
            })
    }

    /// Each row gets only its own status, so a toggle redraws one row rather than all of them.
    private func status(_ row: FileListRow, _ files: [ReviewFile]) -> ViewedMarks.Status {
        guard case .file(let index) = row.kind else { return .unviewed }
        return review.viewed.status(of: files[index])
    }

    private func toggle(_ row: FileListRow) {
        switch row.kind {
        case .directory:
            if review.collapsedDirectories.remove(row.id) == nil {
                review.collapsedDirectories.insert(row.id)
            }
        case .generated:
            review.showsGenerated.toggle()
        case .file:
            break
        }
    }
}

/// A search field like Finder's: magnifier, placeholder, and a clear button once there's text.
/// A styled SwiftUI field rather than an `NSSearchField`, so `FocusState` tracks it exactly:
/// single-letter keys depend on knowing when it has focus. Escape clears it, then leaves it.
/// Search uses it too, with its toggles as the accessory.
struct FilterField<Accessory: View>: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var placeholder = String(localized: "Filter", bundle: .module)
    var help = String(localized: "Words in the path; ^word leaves those out", bundle: .module)
    var clearHelp = String(localized: "Clear Filter", bundle: .module)
    @ViewBuilder var accessory: Accessory
    let onLeave: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // A plain field draws its prompt in the text colour, so the placeholder is drawn here.
            TextField(placeholder, text: $text, prompt: Text(""))
                .textFieldStyle(.plain)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .allowsHitTesting(false)
                    }
                }
                .focused(focus)
                .onExitCommand {
                    if text.isEmpty {
                        focus.wrappedValue = false
                        onLeave()
                    } else {
                        text = ""
                    }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(clearHelp)
            }
            accessory
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focus.wrappedValue = true }
        .overlay {
            if focus.wrappedValue {
                Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
            }
        }
        .help(help)
    }
}

extension FilterField where Accessory == EmptyView {
    init(text: Binding<String>, focus: FocusState<Bool>.Binding, onLeave: @escaping () -> Void) {
        self.init(text: text, focus: focus, accessory: { EmptyView() }, onLeave: onLeave)
    }
}

/// "3/7 viewed", and a checkmark once every file is.
private struct ViewedProgress: View {
    let viewed: Int
    let of: Int

    var body: some View {
        HStack(spacing: 3) {
            Text("\(viewed)/\(of) viewed", bundle: .module)
            if viewed == of {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct FileRowView: View {
    let row: FileListRow
    let files: [ReviewFile]
    let viewed: ViewedMarks.Status
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .directory(let isExpanded), .generated(_, let isExpanded):
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                Text(row.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if case .generated(let count, _) = row.kind {
                    Text(verbatim: "(\(count))").foregroundStyle(.secondary).monospacedDigit()
                }
            case .file(let index):
                let file = files[index]
                Text(String(file.diff.status.letter))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(Self.color(file.diff.status))
                    .frame(width: 12)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: "+\(file.diff.additions) −\(file.diff.deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                switch viewed {
                case .viewed:
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                case .changedSinceViewed:
                    Image(systemName: "circle.lefthalf.filled").font(.caption)
                        .foregroundStyle(.orange)
                case .unviewed:
                    Image(systemName: "checkmark").font(.caption).hidden()
                }
            }
        }
        .padding(.leading, Double(row.depth) * 12)
    }

    static func color(_ status: FileStatus) -> Color {
        switch status {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed, .copied: .blue
        }
    }
}
