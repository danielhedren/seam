import AppKit
import DiffView
import Foundation
import Observation
import SeamCore

/// The settings of SPEC §12, kept in `UserDefaults`. Every load reads them, so a change applies
/// to the next reload of each worktree.
@MainActor
@Observable
public final class AppSettings {
    /// Empty means automatic: `origin/HEAD`, then `origin/main`, then `main`.
    var defaultBase: String { didSet { save(defaultBase, "defaultBase") } }
    var ignoredRefs: [String] { didSet { save(ignoredRefs, "ignoredRefs") } }
    var generatedGlobs: [String] { didSet { save(generatedGlobs, "generatedGlobs") } }
    var editorTemplate: String { didSet { save(editorTemplate, "editorTemplate") } }
    var fontName: String { didSet { save(fontName, "fontName") } }
    var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    var tabWidth: Int { didSet { save(tabWidth, "tabWidth") } }
    /// Minutes between background fetches; 0 is off.
    var fetchInterval: Int { didSet { save(fetchInterval, "fetchInterval") } }
    var defaultMode: DiffLayoutMode { didSet { save(defaultMode.rawValue, "defaultMode") } }
    var whitespace: WhitespaceMode { didSet { save(whitespace.rawValue, "whitespace") } }
    var contextLines: Int { didSet { save(contextLines, "contextLines") } }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<Value>(_ key: String, _ fallback: Value) -> Value {
            defaults.object(forKey: "seam." + key) as? Value ?? fallback
        }
        defaultBase = value("defaultBase", "")
        ignoredRefs = value("ignoredRefs", DetectionSettings().ignoredRefs.map(\.pattern))
        generatedGlobs = value("generatedGlobs", DiffOptions.defaultGeneratedGlobs.map(\.pattern))
        editorTemplate = value("editorTemplate", EditorCommand.zed)
        fontName = value("fontName", "")
        fontSize = value("fontSize", 12)
        tabWidth = value("tabWidth", 4)
        fetchInterval = value("fetchInterval", 0)
        defaultMode = DiffLayoutMode(rawValue: value("defaultMode", "")) ?? .unified
        whitespace = WhitespaceMode(rawValue: value("whitespace", "")) ?? .show
        contextLines = value("contextLines", 3)
    }

    private func save(_ value: some Any, _ key: String) {
        defaults.set(value, forKey: "seam." + key)
    }

    var detection: DetectionSettings {
        DetectionSettings(
            defaultBase: defaultBase.isEmpty ? nil : defaultBase,
            ignoredRefs: ignoredRefs.map(Glob.init))
    }

    var diffOptions: DiffOptions {
        DiffOptions(
            contextLines: contextLines, whitespace: whitespace,
            generatedGlobs: generatedGlobs.map(Glob.init))
    }

    var editor: EditorCommand { EditorCommand(template: editorTemplate) }

    /// Empty name means SF Mono, the system's monospaced font.
    var font: NSFont {
        let size = CGFloat(min(max(fontSize, 8), 32))
        return NSFont(name: fontName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, 8), 32)
    }
}
