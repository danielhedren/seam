# Seam

A native macOS diff viewer for reviewing git worktrees. Each worktree is diffed against the branch
it was cut from, including stacked branches. See `SPEC.md` for the full design and `AGENTS.md`
for the rules every contributor and agent follows.

Status: milestone M5 (review threads, `SPEC.md` §14).

```sh
make setup        # once per clone: installs the pre-commit hook
make check        # format lint, build, tests
make format       # rewrite sources with swift format
make test-all     # plus the app build, the real-repo check and performance budgets
make app          # build the Debug app (make release: the Release app)
make run          # build the Release app and open it (REPO=<path> opens another repo)
make install      # install into ~/Applications and link ~/.local/bin/seam (make uninstall)
make dist         # a zip of the app for another Mac (not notarized: right-click › Open)
make strings      # update the String Catalogs from the app build
swift run seam-debug [path] [--scope all|committed|uncommitted] [--commit <rev>] [--worktrees]
```

Requires Xcode 27 (Swift 6.4) on macOS 26 or later.
