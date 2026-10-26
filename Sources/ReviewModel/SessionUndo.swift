import Foundation

// Undo for the session's own changes: Foundation's UndoManager where it exists. Linux has none,
// and no window to undo from, so there registering does nothing (ADR 0007).
#if canImport(Darwin)
    package typealias SessionUndo = UndoManager
#else
    package final class SessionUndo {
        package func registerUndo<Target: AnyObject>(
            withTarget target: Target, handler: @escaping (Target) -> Void
        ) {}
        package func setActionName(_ name: String) {}
    }
#endif
