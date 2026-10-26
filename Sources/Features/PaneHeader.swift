import DiffModel
import DiffView

/// The header row every pane beside the diff shares, so the file list's, the diff's and the
/// thread panel's header borders meet in one line (SPEC §9). Its height follows the diff font.
enum PaneHeader {
    @MainActor
    static func height(_ session: RepoSession) -> Double {
        DiffScrollView.fileHeaderHeight(for: session.settings.font)
    }
}
