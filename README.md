# Seam

A native macOS diff viewer for reviewing git worktrees and GitHub pull requests. Each worktree is
diffed against the branch it was cut from, including stacked branches; other people's open pull
requests are reviewed in the same diff, without a checkout.

## Install with Homebrew

Seam needs macOS 26 or later on Apple silicon.

```sh
brew tap danielhedren/seam https://github.com/danielhedren/seam
brew trust --cask danielhedren/seam/seam
brew install --cask seam
```

The cask installs Seam.app and the `seam` command. Upgrade with `brew upgrade --cask seam`.

The app isn't notarized, so macOS blocks its first launch: allow it in System Settings › Privacy
& Security › Open Anyway. Or build it yourself with `make install` (below), which needs no
approval.

## About

See `SPEC.md` for the full design and `AGENTS.md` for the rules every contributor and agent
follows. Status: milestones M1–M12 and M14 (`SPEC.md` §14); M13 is next.

## Using Seam

Open a repository with File › Open Repository… (⌘O), by dropping its folder on a window, or by
running `seam` in any of its worktrees (the cask installs the command; otherwise use File ›
Install Command Line Tool…). Each repository gets one window listing every worktree, the files changed against the
branch it was cut from, and the diff.

While the diff or file list has focus, single keys move through the review: `J`/`K` next and
previous file, `N`/`P` next and previous hunk, `V` mark viewed, `1`–`4` pick what to compare, `C`
comment on the selected lines. Every command, with its key, is in the menu bar; ⇧⌘P searches them
all and ⌘K switches worktree. ⇧O outlines the definitions a file's change touches, ⌥⇧V shows
only what changed since you last viewed each file, and ⌃- / ⌃⇧- go back and forward after a jump.

### Pull requests

With the `gh` command installed and signed in, each worktree's row shows its branch's pull request,
and a Pull Requests section under the worktrees lists other people's open ones, review requests
first. Its filter menu hides drafts, bots, authors or labels, or shows only review requests and
pull requests involving you. Selecting one reviews it like a worktree, with GitHub's threads; Seam
fetches it into a store of its own under `~/Library/Application Support/Seam`, and your repository
is only read. GitHub stays read-only: Seam never posts.

### Notifications

Seam says when something needs you: an agent answered, checks finished, a review or comment came
in, a pull request is ready to merge, a review is asked of you, or one you're reviewing got new
commits. Each kind can be turned off in Settings › Notifications. The bell at the right of the
toolbar (⇧⌘N) keeps them, also those from while Seam was in front, and the Dock icon counts the
unread ones.

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
make dist         # tag a release, zip the app and update Casks/seam.rb (publishing is manual)
make strings      # update the String Catalogs from the app build
swift run seam-debug [path] [--scope all|committed|uncommitted] [--commit <rev>] [--worktrees]
```

Requires Xcode 27 (Swift 6.4) on macOS 26 or later.

## License

MIT, see `LICENSE`. The app's `Notices.txt` lists the licences of the code it ships.
