import ReviewModel
import SeamCore
import SwiftUI

/// The toolbar's bell (SPEC §7.10): the unread count as its badge, and the log in a popover.
struct BellButton: View {
    let services: SeamServices
    @Binding var isShown: Bool
    let open: (NotificationLog.Entry) -> Void

    var body: some View {
        Toggle(isOn: $isShown) {
            Label(String(localized: "Notifications", bundle: .module), systemImage: "bell")
        }
        .badge(services.notifications.log.unreadCount)
        .help(
            CommandCatalog.help(
                String(localized: "Show Notifications", bundle: .module), command: "notifications")
        )
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            NotificationList(bell: services.notifications, open: open) {
                services.notifications.markAllRead(on: services.platform)
            }
        }
    }
}

/// The bell's entries, newest first. Showing them marks nothing read.
struct NotificationList: View {
    let bell: NotificationBell
    let open: (NotificationLog.Entry) -> Void
    let markAllRead: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications", bundle: .module).font(.headline)
                Spacer()
                Button(String(localized: "Mark All as Read", bundle: .module), action: markAllRead)
                    .buttonStyle(.link)
                    .disabled(bell.log.unreadCount == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if bell.log.entries.isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "No Notifications", bundle: .module),
                        systemImage: "bell")
                } description: {
                    Text(
                        "News of your worktrees and pull requests is kept here, also what arrives while Seam is in front.",
                        bundle: .module)
                }
                .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(bell.log.entries) { entry in
                            NotificationRow(entry: entry) { open(entry) }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 360)
    }
}

private struct NotificationRow: View {
    let entry: NotificationLog.Entry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Kept when read, so the text of read and unread rows lines up.
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .opacity(entry.isRead ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title).fontWeight(entry.isRead ? .regular : .semibold)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        AgeText(date: entry.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.body).font(.callout)
                        .fontWeight(entry.isRead ? .regular : .medium)
                        .foregroundStyle(entry.isRead ? .secondary : .primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                hovering ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
