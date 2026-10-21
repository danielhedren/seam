import SeamCore
import SwiftUI

/// The menu bar, rendered from `CommandCatalog` (SPEC §9).
struct SeamCommands: Commands {
    @FocusedValue(\.repoSession) private var session
    private let openRepository: () -> Void
    private let installCommandLineTool: () -> Void

    init(openRepository: @escaping () -> Void, installCommandLineTool: @escaping () -> Void) {
        self.openRepository = openRepository
        self.installCommandLineTool = installCommandLineTool
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open Repository…", bundle: .module), action: openRepository)
                .keyboardShortcut("o")
            Divider()
            Button(
                String(localized: "Install Command Line Tool…", bundle: .module),
                action: installCommandLineTool)
        }
        CommandGroup(after: .textEditing) { items(.edit) }
        CommandGroup(after: .sidebar) { items(.view) }
        CommandMenu(String(localized: "Go", bundle: .module)) { items(.go) }
        CommandMenu(String(localized: "Review", bundle: .module)) { items(.review) }
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
                command.title,
                isOn: Binding(
                    get: { session.map(isOn) ?? false },
                    set: { _ in if let session { command.run(session) } })
            )
            .keyboardShortcut(command.keyboardShortcut(for: session))
            .disabled(!enabled)
        } else {
            Button(command.title) { if let session { command.run(session) } }
                .keyboardShortcut(command.keyboardShortcut(for: session))
                .disabled(!enabled)
        }
    }
}
