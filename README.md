# Seam

A native macOS diff viewer for reviewing git worktrees. Each worktree is diffed against the branch
it was cut from, including stacked branches. See `SPEC.md` for the full design and `AGENTS.md`
for the rules every contributor and agent follows.

Status: milestone M1 (headless core).

```sh
make setup        # once per clone: installs the pre-commit hook
make check        # format lint, build, tests
make test-all     # plus the real-repo check and performance budget
swift run seam-debug <worktree> [--scope all|committed|uncommitted] [--worktrees]
```

Requires Xcode 27 (Swift 6.4) on macOS 26 or later.
