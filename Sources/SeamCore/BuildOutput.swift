/// Folders that hold build output (SPEC §6.1). Untracked files in them are left out of the
/// review even when no `.gitignore` covers them: deleting a project leaves its `bin/` and `obj/`
/// behind once the `.gitignore` that hid them is gone with it.
public enum BuildOutput {
    static let folders: Set<Substring> = [
        "bin", "obj", "node_modules", "build", "dist", "out", "target", ".build", "DerivedData",
        "__pycache__", ".gradle", ".next", ".nuxt", ".venv", "venv",
    ]

    /// Whether `path`, relative to the worktree, is inside one of those folders.
    public static func contains(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { folders.contains($0) }
    }
}
