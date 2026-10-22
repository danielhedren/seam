import DiffView
import SeamCore
import SwiftUI

/// The Settings window (SPEC §12). Lists are edited one entry per line.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            Form {
                TextField(
                    String(localized: "Default base", bundle: .module), text: $settings.defaultBase,
                    prompt: Text("origin/HEAD, then origin/main, then main", bundle: .module))
                lines(
                    String(localized: "Never use as a parent", bundle: .module),
                    $settings.ignoredRefs)
                lines(
                    String(localized: "Generated files", bundle: .module), $settings.generatedGlobs)
                Picker(
                    String(localized: "Whitespace", bundle: .module),
                    selection: $settings.whitespace
                ) {
                    Text("Show changes", bundle: .module).tag(WhitespaceMode.show)
                    Text("Ignore changes in amount", bundle: .module).tag(
                        WhitespaceMode.ignoreAmount)
                    Text("Ignore all", bundle: .module).tag(WhitespaceMode.ignoreAll)
                }
                Toggle(
                    String(localized: "Collapse files when marked viewed", bundle: .module),
                    isOn: $settings.collapsesViewed)
                Stepper(value: $settings.contextLines, in: 0...20) {
                    Text("Context lines: \(settings.contextLines)", bundle: .module)
                }
                Picker(
                    String(localized: "Fetch in the background", bundle: .module),
                    selection: $settings.fetchInterval
                ) {
                    Text("Off", bundle: .module).tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { minutes in
                        Text("Every \(minutes) minutes", bundle: .module).tag(minutes)
                    }
                }
            }
            .tabItem { Label(String(localized: "Review", bundle: .module), systemImage: "eye") }

            Form {
                TextField(
                    String(localized: "Font", bundle: .module), text: $settings.fontName,
                    prompt: Text("SF Mono", bundle: .module))
                Stepper(value: $settings.fontSize, in: 8...32) {
                    Text("Size: \(Int(settings.fontSize))", bundle: .module)
                }
                Stepper(value: $settings.tabWidth, in: 1...16) {
                    Text("Tab width: \(settings.tabWidth)", bundle: .module)
                }
                Text("A repository's .editorconfig overrides the tab width.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
                Picker(
                    String(localized: "Diff view", bundle: .module),
                    selection: $settings.layoutMode
                ) {
                    Text("Unified", bundle: .module).tag(DiffLayoutMode.unified)
                    Text("Side by side", bundle: .module).tag(DiffLayoutMode.split)
                }
            }
            .tabItem {
                Label(String(localized: "Display", bundle: .module), systemImage: "textformat")
            }

            Form {
                Picker(
                    String(localized: "Editor", bundle: .module),
                    selection: $settings.editorTemplate
                ) {
                    ForEach(EditorCommand.presets, id: \.template) { preset in
                        Text(preset.name).tag(preset.template)
                    }
                    if !EditorCommand.presets.contains(where: {
                        $0.template == settings.editorTemplate
                    }) {
                        Text("Custom", bundle: .module).tag(settings.editorTemplate)
                    }
                }
                TextField(
                    String(localized: "Command", bundle: .module), text: $settings.editorTemplate)
                Text(
                    "{path} and {line} are filled in; the command runs with your login shell's PATH.",
                    bundle: .module
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem {
                Label(String(localized: "Editor", bundle: .module), systemImage: "pencil")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }

    private func lines(_ title: String, _ values: Binding<[String]>) -> some View {
        LabeledContent(title) { LineListEditor(values: values) }
    }
}

/// One entry per line. The text is kept as typed, so a new empty line survives until it has
/// content; only the parsed entries go to the setting.
private struct LineListEditor: View {
    @Binding var values: [String]
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(height: 60)
            .onAppear { text = values.joined(separator: "\n") }
            .onChange(of: text) {
                values = text.split(separator: "\n").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
    }
}
