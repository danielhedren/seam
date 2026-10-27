import DiffModel
import DiffView
import ReviewModel

/// The header row the file list shares with the diff's sticky header, so their borders meet in
/// one line (SPEC §9). Its height follows the diff font.
enum PaneHeader {
    @MainActor
    static func height(_ session: RepoSession) -> Double {
        DiffScrollView.fileHeaderHeight(for: session.settings.font)
    }
}
