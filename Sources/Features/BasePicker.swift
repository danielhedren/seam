import SeamCore
import SwiftUI

/// The parents a worktree can be compared with (SPEC §5.3), shown from the commit list's base row.
struct BasePicker: View {
    let session: RepoSession
    let review: WorktreeReview
    @State private var otherRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare against", bundle: .module).font(.headline)
            ForEach(review.detection?.candidates ?? [], id: \.ref) { candidate in
                Button {
                    session.setBaseOverride(candidate.ref)
                    session.showsBasePicker = false
                } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(isCurrent(candidate) ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(candidate.name)
                        Spacer()
                        Text(verbatim: Counted.commits(candidate.commitCount))
                            .foregroundStyle(.secondary).monospacedDigit()
                        if candidate.ref == review.detection?.parent?.ref {
                            Text("detected", bundle: .module).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent(candidate) ? .isSelected : [])
            }
            Divider()
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
