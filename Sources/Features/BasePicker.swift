import SeamCore
import SwiftUI

/// The parents a worktree can be compared with (SPEC §5.3), shown from the commit list's base row.
struct BasePicker: View {
    let session: RepoSession
    let review: WorktreeReview
    @State private var otherRef = ""
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Compare against", bundle: .module).font(.headline).padding(.bottom, 6)
            ForEach(review.detection?.candidates ?? [], id: \.ref) { candidate in
                Button {
                    session.setBaseOverride(candidate.ref)
                    session.showsBasePicker = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.callout.weight(.semibold))
                            .opacity(isCurrent(candidate) ? 1 : 0)
                        Text(candidate.name).lineLimit(1).truncationMode(.middle)
                        if candidate.ref == review.detection?.parent?.ref {
                            Text("detected", bundle: .module).font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Spacer(minLength: 12)
                        Text(verbatim: Counted.commits(candidate.commitCount))
                            .foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.quaternary)
                            .opacity(hovered == candidate.ref ? 1 : 0)
                    )
                    .contentShape(Rectangle())
                }
                .help(candidate.name)
                .onHover { inside in
                    if inside {
                        hovered = candidate.ref
                    } else if hovered == candidate.ref {
                        hovered = nil
                    }
                }
                .buttonStyle(.plain)
                // The hover fill reaches past the text, which stays in line with the header.
                .padding(.horizontal, -6)
            }
            Divider().padding(.vertical, 6)
            HStack {
                TextField(String(localized: "Other ref", bundle: .module), text: $otherRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useOtherRef)
                Button(String(localized: "Use", bundle: .module), action: useOtherRef)
                    .disabled(otherRef.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 340)
    }

    private func isCurrent(_ candidate: ParentCandidate) -> Bool {
        candidate.ref == (review.baseOverride ?? review.detection?.parent?.ref)
    }

    private func useOtherRef() {
        guard !otherRef.isEmpty else { return }
        let name = otherRef
        session.showsBasePicker = false
        otherRef = ""
        Task { await session.setTypedBase(name) }
    }
}
