import GitKit
import SeamCore
import SwiftUI

struct FileList: View {
    let session: RepoSession
    @Bindable var review: WorktreeReview
    var filterFocus: FocusState<Bool>.Binding

    var body: some View {
        let files = review.diff?.files ?? []
        let rows = FileTree.rows(
            files.map(\.diff.path), flat: review.flatFileList,
            collapsed: review.collapsedDirectories, filter: review.fileFilter,
            generated: Set(files.indices.filter { files[$0].isGenerated }),
            showsGenerated: review.showsGenerated)
        VStack(spacing: 0) {
            HStack {
                if let diff = review.diff {
                    Text(
                        "\(diff.files.count) files", bundle: .module
                    )
                    Text(verbatim: "+\(diff.additions)").foregroundStyle(.green)
                    Text(verbatim: "−\(diff.deletions)").foregroundStyle(.red)
                }
                Spacer()
                Toggle(isOn: $review.flatFileList) {
                    Image(systemName: "list.bullet.indent")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(String(localized: "Show as Flat List", bundle: .module))
                .accessibilityLabel(String(localized: "Flat list", bundle: .module))
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            TextField(String(localized: "Filter", bundle: .module), text: $review.fileFilter)
                .textFieldStyle(.roundedBorder)
                .focused(filterFocus)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            List(selection: selection(files)) {
                ForEach(rows) { row in
                    FileRowView(row: row, files: files) {
                        toggle(row)
                    }
                    .tag(row.id)
                }
            }
        }
    }

    /// The list follows the diff's scroll position; picking a row scrolls the diff to it.
    private func selection(_ files: [ReviewFile]) -> Binding<String?> {
        Binding(
            get: { review.currentFile },
            set: { id in
                guard let id, files.contains(where: { $0.diff.path == id }) else { return }
                review.currentFile = id
                session.diff.scroll(toFile: id)
            })
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

private struct FileRowView: View {
    let row: FileListRow
    let files: [ReviewFile]
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
                .accessibilityLabel(
                    isExpanded
                        ? String(localized: "Collapse", bundle: .module)
                        : String(localized: "Expand", bundle: .module))
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
            }
        }
        .padding(.leading, Double(row.depth) * 12)
        .accessibilityElement(children: .combine)
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
