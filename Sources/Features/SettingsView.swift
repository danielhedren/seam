import AppKit
import DiffView
import SeamCore
import SwiftUI

/// The Settings window (SPEC §12). Lists are edited one entry per line.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            ReviewSettings(settings: settings)
                .frame(width: 520, height: 600)
                .tabItem { Label(String(localized: "Review", bundle: .module), systemImage: "eye") }
            DisplaySettings(settings: settings)
                .frame(width: 520, height: 300)
                .tabItem {
                    Label(String(localized: "Display", bundle: .module), systemImage: "textformat")
                }
            EditorSettings(settings: settings)
                .frame(width: 520, height: 200)
                .tabItem {
                    Label(String(localized: "Editor", bundle: .module), systemImage: "pencil")
                }
        }
        .formStyle(.grouped)
    }
}

struct ReviewSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField(
                    String(localized: "Default base", bundle: .module), text: $settings.defaultBase,
                    prompt: Text("Automatic", bundle: .module))
                LineListEditor(
                    title: String(localized: "Never use as a parent", bundle: .module),
                    values: $settings.ignoredRefs)
            } header: {
                Text("Base", bundle: .module)
            } footer: {
                Text(
                    "Automatic tries origin/HEAD, then origin/main, then main. Refs matching a pattern, one per line, are never picked as a worktree's parent.",
                    bundle: .module
                )
                .settingsFootnote()
            }

            Section {
                Picker(
                    String(localized: "Whitespace", bundle: .module),
                    selection: $settings.whitespace
                ) {
                    Text("Show all changes", bundle: .module).tag(WhitespaceMode.show)
                    Text("Ignore changes in amount", bundle: .module).tag(
                        WhitespaceMode.ignoreAmount)
                    Text("Ignore all whitespace", bundle: .module).tag(WhitespaceMode.ignoreAll)
                }
                NumberStepper(
                    title: String(localized: "Context lines", bundle: .module),
                    value: $settings.contextLines, range: 0...20)
                Toggle(
                    String(localized: "Collapse files when marked viewed", bundle: .module),
                    isOn: $settings.collapsesViewed)
                LineListEditor(
                    title: String(localized: "Generated files", bundle: .module),
                    values: $settings.generatedGlobs)
            } header: {
                Text("Diff", bundle: .module)
            } footer: {
                Text(
                    "Files matching a pattern, one per line, or marked linguist-generated in .gitattributes start collapsed under Generated. Changes apply the next time a worktree loads.",
                    bundle: .module
                )
                .settingsFootnote()
            }
        }
    }
}

struct DisplaySettings: View {
    @Bindable var settings: AppSettings
    @State private var fonts: [MonospacedFont] = []

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Font", bundle: .module), selection: $settings.fontName) {
                    Text("SF Mono", bundle: .module).tag("")
                    Divider()
                    ForEach(fonts) { font in Text(font.family).tag(font.name) }
                }
                NumberStepper(
                    title: String(localized: "Size", bundle: .module),
                    value: Binding(
                        get: { Int(settings.fontSize) }, set: { settings.fontSize = Double($0) }),
                    range: 8...32)
                NumberStepper(
                    title: String(localized: "Tab width", bundle: .module),
                    value: $settings.tabWidth, range: 1...16)
            } footer: {
                Text(
                    "View › Make Text Bigger and Make Text Smaller change the size too. A repository's .editorconfig overrides the tab width.",
                    bundle: .module
                )
                .settingsFootnote()
            }
            Section {
                Picker(
                    String(localized: "Diff layout", bundle: .module),
                    selection: $settings.layoutMode
                ) {
                    Text("Unified", bundle: .module).tag(DiffLayoutMode.unified)
                    Text("Side by side", bundle: .module).tag(DiffLayoutMode.split)
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear { fonts = MonospacedFont.installed(keeping: settings.fontName) }
    }
}

struct EditorSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
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
            } footer: {
                Text(
                    "Review › Open in Editor (O) runs the command with {path} and {line} filled in, using your login shell's PATH.",
                    bundle: .module
                )
                .settingsFootnote()
            }
        }
    }
}

/// A fixed-pitch family for the Font picker, by the PostScript name of its regular face, which
/// `AppSettings.font` loads.
struct MonospacedFont: Identifiable, Hashable {
    var family: String
    var name: String
    var id: String { name }

    /// Every installed fixed-pitch family, plus `current` when it's a font that isn't among them,
    /// so a setting from before the picker still shows.
    @MainActor
    static func installed(keeping current: String) -> [MonospacedFont] {
        let manager = NSFontManager.shared
        var fonts = manager.availableFontFamilies.compactMap { family -> MonospacedFont? in
            guard family != "SF Mono", !family.hasPrefix("."),
                let members = manager.availableMembers(ofFontFamily: family),
                let regular = members.first(where: isRegular) ?? members.first,
                let name = regular.first as? String,
                NSFont(name: name, size: 12)?.isFixedPitch == true
            else { return nil }
            return MonospacedFont(family: family, name: name)
        }
        if !current.isEmpty, !fonts.contains(where: { $0.name == current }) {
            fonts.append(MonospacedFont(family: current, name: current))
        }
        return fonts.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    /// `availableMembers` rows are [PostScript name, style, weight, traits]; 5 is regular weight.
    private static func isRegular(_ member: [Any]) -> Bool {
        guard member.count >= 4, let weight = member[2] as? Int,
            let traits = member[3] as? UInt
        else { return false }
        return weight == 5 && NSFontTraitMask(rawValue: traits).isDisjoint(with: .italicFontMask)
    }
}

/// A number with a stepper beside it, as macOS settings show one.
private struct NumberStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value, format: .number).monospacedDigit()
                Stepper(title, value: $value, in: range).labelsHidden()
            }
        }
    }
}

/// One entry per line. The text is kept as typed, so a new empty line survives until it has
/// content; only the parsed entries go to the setting.
private struct LineListEditor: View {
    let title: String
    @Binding var values: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 76)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .onAppear { text = values.joined(separator: "\n") }
        .onChange(of: text) {
            values = text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
    }
}

extension Text {
    fileprivate func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
