# Seam

A native macOS diff viewer for reviewing git worktrees. Each worktree is diffed against the branch
it was cut from, including stacked branches. See `SPEC.md` for the full design and `AGENTS.md`
for the rules every contributor and agent follows.

Status: milestone M5 (review threads, `SPEC.md` §14).

## Using Seam

Open a repository with File › Open Repository… (⌘O), by dropping its folder on a window, or by
running `seam` in any of its worktrees (install the command with File › Install Command Line
Tool…). Each repository gets one window listing every worktree, the files changed against the
branch it was cut from, and the diff.

While the diff or file list has focus, single keys move through the review: `J`/`K` next and
previous file, `N`/`P` next and previous hunk, `V` mark viewed, `1`–`4` pick what to compare, `C`
comment on the selected lines. Every command, with its key, is in the menu bar; ⇧⌘P searches them
all and ⌘K switches worktree.

### Review threads with an agent

Comment on lines in the diff, then Review › Copy Prompt for Agent and paste it to the agent
working in that worktree. The agent reads and answers with the `seam` command:

```sh
seam threads                         # this worktree's open threads
seam reply <id> "Done: ..." --as claude
seam comment src/a.cs:12-14 "Why?"   # or open a thread itself
seam wait --since <time>             # block until threads change
seam --help                          # everything else
```

## Building

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
