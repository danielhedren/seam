import ReviewModel
import SeamCore
import SwiftUI

/// The menu bar, rendered from `CommandCatalog` (SPEC §9).
struct SeamCommands: Commands {
    @FocusedValue(\.repoSession) private var session
    private let requests: OpenRequests
    private let openRepository: () -> Void
    private let openRecent: (URL) -> Void
    private let clearRecent: () -> Void
    private let installCommandLineTool: () -> Void
    private let newWindow: () -> Void
    private let showShortcuts: () -> Void

    init(
        requests: OpenRequests, openRepository: @escaping () -> Void,
        openRecent: @escaping (URL) -> Void, clearRecent: @escaping () -> Void,
        installCommandLineTool: @escaping () -> Void, newWindow: @escaping () -> Void,
        showShortcuts: @escaping () -> Void
    ) {
        self.requests = requests
        self.openRepository = openRepository
        self.openRecent = openRecent
        self.clearRecent = clearRecent
        self.installCommandLineTool = installCommandLineTool
        self.newWindow = newWindow
        self.showShortcuts = showShortcuts
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Window", bundle: .module), action: newWindow)
                .keyboardShortcut(CommandCatalog.newWindow)
            Divider()
            Button(String(localized: "Open Repository…", bundle: .module), action: openRepository)
                .keyboardShortcut(CommandCatalog.openRepository)
            Menu(String(localized: "Open Recent", bundle: .module)) {
                ForEach(requests.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { openRecent(url) }
                }
                Divider()
                Button(String(localized: "Clear Menu", bundle: .module), action: clearRecent)
                    .disabled(requests.recent.isEmpty)
            }
            Divider()
            items(.file)
            Divider()
            Button(
                String(localized: "Install Command Line Tool…", bundle: .module),
                action: installCommandLineTool)
        }
        CommandGroup(after: .textEditing) {
            Menu(SeamCommand.Menu.find.name) { items(.find) }
        }
        CommandGroup(after: .sidebar) { items(.view) }
        CommandMenu(String(localized: "Go", bundle: .module)) { items(.go) }
        CommandMenu(String(localized: "Review", bundle: .module)) { items(.review) }
        // No shortcut: ⇧⌘? is the Help menu's search field.
        CommandGroup(replacing: .help) {
            Button(String(localized: "Keyboard Shortcuts", bundle: .module), action: showShortcuts)
        }
    }

    @ViewBuilder
    private func items(_ menu: SeamCommand.Menu) -> some View {
        let commands = CommandCatalog.items(in: menu)
        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
            if index > 0, commands[index - 1].section != command.section { Divider() }
            item(command)
        }
    }

    @ViewBuilder
    private func item(_ command: SeamCommand) -> some View {
        let enabled = session.map(command.isEnabled) ?? false
        if let isOn = command.isOn {
            Toggle(
                command.title(for: session),
                isOn: Binding(
                    get: { session.map(isOn) ?? false },
                    set: { _ in if let session { command.run(session) } })
            )
            .keyboardShortcut(command.keyboardShortcut(for: session))
            .disabled(!enabled)
        } else {
            Button(command.title(for: session)) { if let session { command.run(session) } }
                .keyboardShortcut(command.keyboardShortcut(for: session))
                .disabled(!enabled)
        }
    }
}
