# Seam — spec

A native macOS diff viewer for reviewing code in worktree-heavy repositories. You open a repo, see
every worktree, pick one, and get that worktree's diff against the branch it was cut from. You
never look up a base commit by hand.

Status: spec only. Nothing is implemented.

---

## 1. Problem

The current workflow for reviewing a worktree in hunk:

1. `git log` in the worktree.
2. Find where the branch left its parent by eye.
3. `hunk diff <that commit>`.

`git merge-base origin/main HEAD` doesn't solve this for stacked branches. Measured on a real
repository, on a worktree `feat/b` stacked on `feat/a`:

| Base | Commits | Diff |
|---|---|---|
| `merge-base origin/main HEAD` | 17 | 67 files, +1123 −1160 |
| actual parent `origin/feat/a` | 5 | 19 files, +454 −948 |

`feat/a` has merged main twice since `feat/b` was cut from it. Diffing against main pulls
all of feat/a into the review.

That repo has 20 worktrees, several outside the repo directory (`~/Code/.worktrees/…`,
`~/Code/other-repo`). Switching between them means `cd` plus repeating the steps above.

## 2. Goals

1. **The diff is the focus.** When reviewing, the diff takes the window. Sidebars are useful and
   can be hidden with one key.
2. **The correct base, automatically,** including for stacked branches, branches that have merged
   main, and uncommitted work.
3. **Every worktree in one place,** with enough status to see which ones are moving, and switching
   in one keystroke.
4. **Fast.** Native rendering. Large diffs (20k+ lines) scroll smoothly.

## 3. Non-goals

- Not a git client: no staging, committing, rebasing, pushing, or conflict resolution.
- No editing files in the diff.
- Hosted PRs (GitHub/Azure DevOps review threads).
- Non-git VCS. Submodule contents (a submodule shows as one changed pointer).
- Distribution, App Store, sandboxing, auto-update. Personal tool, built locally.

## 4. Terms

| Term | Meaning |
|---|---|
| **Repo** | A git repository, identified by its common git dir (`git rev-parse --git-common-dir`). Every worktree of one repo maps to the same repo. |
| **Worktree** | An entry from `git worktree list --porcelain`, the main worktree included. |
| **Parent** | The branch a worktree's branch was cut from, e.g. `origin/feat/a`. |
| **Base** | The commit the diff starts from: `merge-base(parent, HEAD)`. |
| **Review diff** | Base → working tree for one worktree (see §6). |

## 5. Base detection

This is the core feature. It has to be correct and run in well under a second.

### 5.1 Algorithm

Inputs: worktree HEAD, the current branch name `B`, and every ref under `refs/heads` and
`refs/remotes`.

1. **Exclude refs that are not candidate parents:**
   - `B` itself, plus its own remote copy (the ref `B`'s upstream points to, if it has the same
     branch name, and `<remote>/B` for every remote). The exception is the default base: local
     `main` is reviewed against `origin/main` (F13).
   - Symbolic refs (`refs/remotes/*/HEAD`).
   - Refs matching user ignore globs (§12).
2. **Refs that contain HEAD** (`git for-each-ref --contains HEAD`) are either a branch HEAD was
   cut from, at the same commit or moved on since (F8, F14), or a branch cut from HEAD (F6, F12).
   The graph can't tell which. Such a ref is a parent, with 0 unique commits, when it is the
   default base or `B`'s upstream; failing that, when its local branch was created no later than
   `B` (first reflog entry). With no reflog evidence, a ref at HEAD's exact commit is a parent and
   a ref ahead of HEAD is a descendant. If any parent is found, stop here: base = HEAD.
3. **Exclude descendants:** every other ref that contains HEAD, e.g. a branch stacked on top of
   this one. Keeping them would hide every commit.
4. **Find the commits unique to this branch:** `git rev-list --boundary --stdin` fed `HEAD` and
   `^<ref>` for every remaining ref. Lines without a prefix are the commits no other branch has.
   Lines with a `-` prefix are the boundary commits where those meet other branches. No boundary
   means HEAD shares no history with any ref: no parent, base = the empty tree.
5. **Find candidate parents:** `git for-each-ref --contains <boundary>` for each boundary.
   - A ref containing **every** boundary lacks exactly the unique commits, which is the minimum
     possible count, so those refs are the candidates and nothing needs counting.
   - Otherwise (e.g. a stacked branch that merged a newer main than its parent has), every ref
     containing at least one boundary is a candidate, counted with
     `git rev-list --count HEAD ^<ref>` once per distinct tip.
6. **Rank candidates** by commit count, smallest first. Break ties in this order:
   1. A ref whose tip equals a boundary commit (the parent hasn't moved since).
   2. The upstream of `B`, if it is a different branch name (a branch created with
      `git switch -c x --track origin/parent`).
   3. The repo's default base (`origin/HEAD` → usually `origin/main`).
   4. Remote refs over local refs (they reflect what was pushed).
   5. Most recent committer date.
   Because of the count, a local parent that's ahead of its remote wins over the remote. Its
   unpushed commits count as part of the base, not the review.
7. **Base** = `merge-base(chosen parent, HEAD)`. The default base is always added to the
   candidate list (with its count) so the picker can offer "vs main" for the whole stack.

Measured on the feat/b worktree (347 refs): the whole detection takes ~120–150 ms through
`seam-debug`. The boundary commit is contained only by a local `feat/a` and
`origin/feat/a`, both at 5 unique commits; tie-break rule 4 picks the
remote. A naive loop calling `merge-base` + `rev-list --count` once per ref took 11 s, so step 5's
"contains every boundary" shortcut is what keeps the common case at a handful of git calls.

### 5.2 Required behaviour (acceptance fixtures)

Each case below becomes a fixture: a script that builds a throwaway repo, plus the expected parent
and base.

| # | Scenario | Expected parent |
|---|---|---|
| F1 | Branch off main, no merges | `origin/main` |
| F2 | Branch off main that later merged main | `origin/main`; base = the last merged main commit, so main's changes are not in the diff |
| F3 | Stacked: C on B on main | B |
| F4 | Stacked, where B has merged main since C branched (the shape that motivated §5.1) | B; base = merge-base(B, C) |
| F5 | Stacked, where C has merged a newer B | B; base = newer B commit |
| F6 | A branch D stacked on C exists | C's parent is unaffected by D (D excluded in step 3) |
| F7 | C's upstream is its own pushed remote branch | Upstream is ignored as a candidate; result as for F3 |
| F8 | No unique commits (fresh worktree, nothing committed) | Default base. Diff = uncommitted changes only |
| F9 | Detached HEAD | Same algorithm with no `B` exclusions. The worktree is labelled "detached" |
| F10 | B squash-merged into main and its branch deleted | `origin/main` once B's refs are gone. While B's remote ref still exists: B, with the warning from §5.4 |
| F11 | Stacked, where local B has commits not yet pushed to `origin/B`, and C is built on them | local B; those commits are not in C's diff |
| F12 | D freshly cut from C (same commit, nothing committed yet) | C's parent is unaffected by D; D's parent is C with 0 commits (step 2) |
| F13 | The main worktree, local `main` behind `origin/main` | `origin/main` with 0 commits; diff = uncommitted changes |
| F14 | Fresh worktree with nothing committed, after main has moved on | `origin/main` with 0 commits; base = HEAD |

Plus one opt-in check on a real repository: a pinned commit of a stacked branch must pick its
parent and give the expected committed-scope diff. The repository, commit, parent and expected
numbers live in `local.mk`, which stays out of git (§10), so the check skips anywhere else. Line
counts can differ slightly from plain `git diff --shortstat` because Seam diffs with
`--histogram`.

### 5.3 Overrides

- The commit list's base row shows the chosen parent ("Branched from
  origin/feat/a"). Clicking it, or `b`, opens a picker listing all
  candidates with their commit counts, plus a field for any other ref or commit.
- A manual choice is saved per repo and branch (§11) and wins over detection until it's cleared.
  If the saved ref disappears, fall back to detection and show a notice.

### 5.4 Stale parent

If the parent has been squash-merged, its commits never reach main. Detection then keeps choosing
the old parent, and the diff shows only the commits after it. Signals:

- The parent's remote ref is `[gone]` after a fetch. The local branch may still exist.
- The parent is a local branch with no remote ref, and it is fully contained in the default base
  or a remote candidate. A sibling branch cut from the same local parent also contains it, so
  local siblings don't count.

The check reruns with detection, on every ref change, and the worktree's row carries a "stale
parent" marker. Dismissing the banner ("Keep X", also in the Review menu) is remembered per
worktree. On either signal, show a non-blocking banner: "Parent `X` looks merged — diff against `origin/main`
instead?" Asking `gh` whether the PR is merged is out of scope for v1.

### 5.5 No git operations

Seam reads whatever refs are local and runs no git operation that changes them: no fetch, pull or
prune. Refs updated from a terminal reach every row through the watcher.

## 6. The review diff

### 6.1 Contents

For a worktree with base `M`:

- **Tracked changes:** `git diff --no-ext-diff --no-color --histogram -M -C --find-renames <M>`.
  This includes committed, staged and unstaged changes.
- **Untracked files:** `git ls-files --others --exclude-standard`, each shown as a full addition.
  Seam never runs `git add -N`, because it must not modify the index.

### 6.2 Scopes

Scopes are named runs of the commit list (§7.2.1), picked there or with keys `1`/`2`/`3` when the
diff has focus:

| Scope | Range | Default |
|---|---|---|
| **All** | base → working tree (+ untracked) | ✓ |
| **Committed** | base → HEAD | |
| **Uncommitted** | HEAD → working tree (+ untracked) | |

The commit list (§7.2.1) generalises the scopes: each scope is a run of its rows, and the reader
can pick any other run instead, such as only the latest commit. A picked run diffs from its oldest
commit's first parent to its newest commit, or to the working tree when the run includes
"Uncommitted changes". A run that covers the same rows as a scope is that scope. Picked commits
are not persisted, and a rebase or reset that removes one falls back to the scope. Picking another
range (scope, commits or parent) scrolls the diff to the top; a live reload of the same range
keeps the position.

### 6.3 Diff options

- Whitespace: show / ignore changes in amount (`-b`) / ignore all (`-w`). Default: show.
- Context lines: default 3. Context can be expanded per hunk (§7.4).
- Renames and copies: shown as one entry, old → new, with the similarity %.
- Binary files: one entry showing "binary, size a → b". Images get a side-by-side preview (PNG,
  JPEG, GIF, SVG, PDF first page).
- Mode changes and symlinks: shown as metadata on the file entry.
- Files over 1 MB or 20k lines: collapsed by default. Click to load.
- **Generated files** are collapsed by default and grouped under a separate "Generated" heading:
  `.gitattributes` `linguist-generated`, plus user globs. Default globs: `**/Generated/**`,
  `**/*.g.cs`, `**/package-lock.json`, `**/*.lock`.

## 7. UI

### 7.1 Window

```
┌ Worktrees ─────────────┬ Files ────────────┬ Diff ──────────────────────────────────┐
│ feat-b             2m  │ 19 files +454 −948│ ▾ M src/Orders.Svc/Delivery.cs ☐ Viewed│
│ 5 commits · 19 files   │ ▾ src/Orders.Svc  │   DeliveryHandler › Handle             │
│ ✎2         +454 −948   │   M Delivery.cs ✓ │                                        │
│ feat-a             1h  │   M Options.cs    │  (side-by-side or unified diff)        │
│ main                   │ ▾ contracts/…     │                                        │
│ old-spike  stale parent│   M openapi.yaml  │                                        │
├ Commits ───────────────┤ ▸ Generated (3)   │                                        │
│ Uncommitted changes    │                   │                                        │
│ Remove the preview     │                   │                                        │
│ Branched from feat/a   │                   │                                        │
└────────────────────────┴───────────────────┴────────────────────────────────────────┘
```

- Three panes: worktrees | files | diff. `⌘\` hides or shows both sidebars, `⌘⌥\` only the
  worktree list. Pane widths are remembered.
- One window per repo, listing only that repo's worktrees. Opening another repo opens another
  window; ``⌘` `` and the Window menu move between them. Window tabs are off: with a sidebar, macOS
  puts the tab bar beside it, so the tab bar moves between tabs whose sidebars differ. A window's
  title is the repo's name. File › New Window (⌘N) opens the welcome screen.
- A window's frame, titlebar and toolbar are the same from its first frame: while the repo opens,
  the split view and its toolbar are already there, the toolbar's buttons disabled. The welcome
  screen has the same toolbar height, so opening a repo in it moves nothing.
- The open repos are the workspace. Quitting and relaunching reopens them, the first in the
  launch window and each of the rest in its own window, in the order they were opened. Each repo
  remembers its window's frame, also after its window closes, and its window opens in that
  frame; a frame on a display that's gone is ignored. A welcome window that opens a repo keeps
  its frame. Closing a repo's window takes it out of the workspace; quitting doesn't. A launch
  path (`seam`, `make run`) opens among them.
- Dark and light themes, following the system.

### 7.2 Worktree list

Each row shows:
- The worktree directory name in bold, and the branch name if it differs.
- The commits unique to the branch (from §5) and the files changed against its base ("5 commits ·
  19 files"), `✎N` uncommitted files, and the line totals (`+454 −948`) on the right. Totals
  include uncommitted changes and untracked text files, and are measured from the same base as
  the diff.
- Time since the last change in that worktree: the newest of the HEAD commit time, the changed
  files' modification times (from `git status`), and the last watcher event for it.
- State markers: detached, locked, prunable (from porcelain output), missing directory, stale
  parent (§5.4).

Sorting: most recently changed first (default), or by name. The main worktree is pinned to the
top. Worktrees whose directory is missing are listed dimmed, and can be hidden.

Switching: `⌘1`…`⌘9` pick by position, `⌘[`/`⌘]` go to the previous or next worktree, and `⌘K`
opens fuzzy search over worktree and branch names. Each worktree keeps its own scroll position,
selected file, and scope.

### 7.2.1 Commit list

Under the worktree list, the selected worktree's commits since the base, newest first, following
first parents (a merge from main is one row):

- An "Uncommitted changes" row on top, with the number of changed files, only while there are
  any. Without it, selecting every commit is the All scope, so later edits still show.
- One row per commit: subject, short SHA, age. At most 500 are listed.
- The base at the bottom, marked as the branch point ("Branched from origin/main", its SHA and
  subject). It is not selectable: every range is measured from it or from a commit above it.

The rows the diff covers are selected; selecting other rows (click, ⇧-click, arrow keys) picks a
new run (§6.2), and a ⌘-click selection is filled to a contiguous run. "Show All" returns to the
All scope. The divider between the worktree and commit lists keeps its position across worktree
switches and launches.

### 7.3 File list

- A tree grouped by directory with single-child directories compacted (`src/Orders.Service/…`),
  or a flat list (toggle). Status letter (A/M/D/R/C), `+/−` counts, and a viewed checkmark per
  file.
- The header shows totals and the viewed count ("7/19 viewed").
- Filter field (`⌘F` while the file list has focus) matching on path: space-separated terms,
  ignoring case, not a regex. Every plain term must appear in the path; a term starting with `^`
  must not (`^test` hides test files, `delivery ^test` shows delivery files except tests). Only
  plain terms expand the tree; a filter that only leaves files out keeps folders as they were.
  The filter narrows the diff to the same files. The file list follows every keystroke; the diff
  follows once typing pauses for 300 ms, and scrolls to the top. Clearing the filter applies at
  once.
- The diff lists files in the file list's order: at each level folders before files, then by
  name, with generated files last.
- Selecting a file scrolls the diff to it. The diff is one continuous scroll of all files, and
  the file list follows the scroll position.

### 7.4 Diff view

- Side-by-side and unified modes (`⇆` toggles, key `s`). The mode is global: toggling it
  changes every worktree, and it is remembered.
- A sticky file header per file: a collapse chevron, status, path, `+/−` counts (left out when
  both are 0), and the viewed checkbox with its label at the right edge, so it sits in the same
  place on every file. The chevron and checkbox are drawn at the text's height.
- Syntax highlighting (§8.4).
- **Word-level highlights within changed lines:** pair removed and added lines inside a hunk by
  similarity, then highlight the changed tokens. Unpaired lines get no word highlights.
- Marking a file viewed collapses it (a setting, on by default); unmarking, undoing or a later
  change to the file opens it again. Review › Hide Whitespace Changes (`-w`) toggles per
  worktree, starting from the whitespace setting.
- **Expanding context:** each gap between hunks has controls for "↑ 20 lines", "↓ 20 lines" and
  "all". These use the full file contents from the base and the working tree.
- Line numbers for both sides. Line wrapping is off by default (toggle `w`). Without wrapping,
  unified mode scrolls horizontally; split mode keeps each side at half the width and clips long
  lines at the column edge, so both sides stay in view.
- Text selection and copy work in both modes. In side-by-side mode a selection stays within one
  side.
- Each hunk's header names the definitions around its first change, outermost first
  (`GetOrderOptionsHandler › Handle`), from the tree-sitter parse: types, functions, methods,
  constructors and properties in C#, TypeScript, JavaScript and Rust. Git's line ranges
  and section heading aren't shown; the ranges repeat the gutter, and the heading is git's guess
  at the last unindented line, which in C# names the class or namespace. A header without a name
  shows only as a thin band where nothing else marks a jump in line numbers (the file's text isn't
  loaded): not above the first hunk, and not where a gap row already separates the hunks. Once a
  gap is fully expanded, the hunk below it has no header at all. The header rows stay in the row
  model at no height, so hunk navigation still stops at them.

### 7.5 Keyboard

Every review action has a key. The defaults are vim-ish, like hunk:

| Key | Action |
|---|---|
| `j` / `k` | next / previous file |
| `n` / `p` | next / previous hunk (across files) |
| `space` / `⇧space` | page down / up |
| `v` | toggle viewed, then jump to the next unviewed file |
| `s` | side-by-side / unified |
| `w` | wrap |
| `1` `2` `3` | scope |
| `4` | latest commit only |
| `x` | collapse / expand the current file |
| `o` | open the current line in the editor |
| `c` | comment on the selected lines (§7.7) |
| `t` | open the thread on the current line |
| `⌥⌘0` | thread panel |
| `b` | base picker |
| `r` | force reload |
| `⌘\` | toggle sidebars |
| `⌘K` | worktree switcher |
| `⌘F` / `⌘G` / `⇧⌘G` | find in the diff, next / previous match (`⌘F` filters while the file list has focus) |
| `⌘⇧P` | command palette (every action) |

### 7.6 Open in editor

Configurable command template. Presets for Zed (`zed {path}:{line}`), VS Code
(`code -g {path}:{line}`), Rider and Cursor; the default is the first of those that is installed,
else Zed. `{path}` is the path inside the worktree being reviewed, so the file opens in that
worktree.

The command runs with `/bin/sh` and the PATH of the user's login, interactive shell, read once.
When a preset's command isn't on that PATH, Seam uses the command-line tool inside the installed
app instead.

### 7.7 Review threads

Comments on lines of a worktree's diff, in threads, as on a GitHub pull request: the reader
reviews an agent's work and the agent answers, or an agent reviews and the reader answers.

- **A thread** is anchored to a file, a side (new or old) and a line range, and holds comments in
  order. Each comment has an author (`you`, or the agent name a `seam` call gives), a Markdown
  body and a time. A thread is open or resolved. Only its author resolves it: the reader resolves
  threads they opened, an agent resolves threads it opened. Anyone may reply, and a reply to a
  resolved thread reopens it.
- **Creating:** select lines in the diff (or put the cursor on one) and press `c`, or Review ›
  Comment, or right-click: "Comment on Line N" for the clicked line, or "Comment on Lines N–M"
  when the click is inside a selection, which a right-click elsewhere replaces with the clicked
  line. A composer opens in the thread panel; ⌘↩ posts.
- **In the diff:** a commented range gets a marker in the gutter and a compact row after its last
  line: author, the first line of the latest comment, the number of comments, and open or
  resolved. Clicking it, or `t` on that line, opens the thread in the panel. Resolved threads
  show only the gutter marker unless Review › Show Resolved Threads is on.
- **The thread panel** (an inspector on the right, `⌥⌘0`) lists the worktree's threads by file,
  open ones first, with the selected thread's conversation, a reply box, and Resolve or Reopen
  for its author. Agent replies appear live. Its header has Copy Prompt for Agent and a close
  button.
- **Following edits:** a thread keeps the text of its lines. When the file changes, it moves to
  the nearest place where those lines still appear; when they're gone it is outdated, shown in
  the panel with its original lines, not in the diff. Moving and outdating are decided per diff
  load, never written back.
- **Handing threads to an agent:** Review › Copy Prompt for Agent puts on the clipboard a short
  prompt that tells the agent to run `seam threads`, address each open thread, and answer with
  `seam reply`, and not to resolve threads it didn't open. Seam doesn't type into terminals.
- **Storage:** outside the repository, which Seam never writes to: one JSON file per repo under
  `~/Library/Application Support/Seam/threads/`, keyed by the repo's common git directory, with
  threads grouped by worktree path. The app and the `seam` command both read and write it:
  every change is a read-modify-write under an exclusive `flock` on a lock file beside it,
  written to a temporary file and renamed into place. The app watches the directory and reloads
  on change. The file carries a format version; an unknown version is refused, not overwritten.

## 8. Technical design

### 8.1 Language and toolchain

- **Swift 6.4** (Xcode 27), Swift 6 language mode, complete strict concurrency checking. Warnings
  are errors.
- **SwiftUI** for the app frame: window, sidebars, toolbar, settings, palette. **AppKit** for the
  diff view (§8.5), wrapped in `NSViewRepresentable`. SwiftUI is Apple's current default. AppKit
  is used only where SwiftUI can't meet the §8.7 budgets.
- Minimum macOS 26, Apple silicon only.
- Rejected: Rust + Tauri, and Electron. Both give up native text rendering, menus, accessibility
  and FSEvents integration, which are the reason for a native app.
- **Formatting and linting:** `swift format` (ships with the toolchain), with a checked-in
  `.swift-format`. `swift format lint --strict` is part of `make check`. No SwiftLint, to avoid an
  extra toolchain dependency.
- **Dependencies:** as few as possible, each version pinned exactly in `Package.resolved` and
  added only after review:
  - SwiftTreeSitter and the grammar packages
  - swift-argument-parser (CLI)
  - swift-snapshot-testing (tests only)
- **Project layout:** a thin Xcode app target, with all code in a local Swift package. The Xcode
  project (`App/Seam.xcodeproj`) contains only the app entry point (`App/Seam/SeamApp.swift`),
  assets and signing, so merges never touch `project.pbxproj` for code changes. Scenes and menus
  live in `Features` (`SeamScenes`, `SeamCommands`) for the same reason. The app is not sandboxed:
  it runs the user's `git` on arbitrary repositories. `make app` builds it, `make run` opens it.
- **App icon:** an Icon Composer document (`App/Seam/AppIcon.icon`: `icon.json` plus SVG layers)
  that actool compiles into the bundle. Two panes, old and new, with red and green lines, joined
  by a stitched seam.
- **Versions:** `CFBundleShortVersionString` is `MARKETING_VERSION` in the project.
  `CFBundleVersion` is the commit count (`git rev-list --count HEAD`), which the Makefile passes
  to every app build, so builds from different commits are distinguishable.

### 8.2 Architecture

**Functional core, imperative shell.** Git output parsing, base detection ranking, review-diff
assembly, intra-line diffing, row layout and viewed-state invalidation are pure functions over
value types. Processes, file watching, persistence and UI sit around them and call in. This makes
nearly all of the logic testable without git or a window.

**Modules** (SwiftPM targets). Dependencies only point downward, and the compiler enforces it:

```
SeamApp (app target: entry point only)
  └ Features      @Observable models, SwiftUI views per pane, scenes and menus
      ├ DiffView      AppKit diff view, row model, Core Text drawing
      ├ Highlighting  tree-sitter wrapper, highlight cache
      └ SeamCore      domain: Repo, Worktree, BaseDetector, ReviewDiff, IntraLineDiff, ViewedState
          └ GitKit    process runner, git commands, porcelain/-z/patch parsers
seam (CLI executable) ─ depends only on the URL scheme contract
seam-debug (M1)       ─ SeamCore
```

- **State management:** observable models (`@Observable`), the pattern Apple recommends for
  SwiftUI. One `RepoSession` (`@MainActor`) per window owns the worktree list, selection, and one
  `WorktreeReview` per worktree. Views read the models and send intents as method calls. Data
  flows one way: services → models → views.
  - Rejected: TCA. It adds a large dependency and longer compile times, which a single-developer
    app with one main screen doesn't benefit from.
- **Concurrency:** structured concurrency throughout. Long-lived work runs in actors:
  - `RepoMonitor`: FSEvents, debouncing.
  - `ReviewService`: diff computation.
  - `BlobStore`: the `cat-file --batch` process.

  Results arrive on the main actor. Each selection change cancels the task tree for the previous
  selection. Nothing blocks the main thread on I/O.
- **Dependency injection:** protocol seams passed in through initialisers: `GitClient`,
  `FileSystem`, `FileWatcher`, `Clock`, `Store`. No singletons, no DI framework. Tests and SwiftUI
  previews use in-memory fakes.
- **Errors:** typed domain errors (`GitError`, `DetectionError`, …) as `throws(E)` where the set is
  closed. The UI turns them into inline banners (§9). They never cause a crash or a modal unless
  data would be lost, and Seam has no such case.
- **Observability:** `os.Logger` with subsystem `com.danielhedren.seam` and a category per module.
  `OSSignposter` intervals around every operation with a §8.7 budget, so Instruments shows them
  directly. No analytics or telemetry.
- **Decisions** are recorded as short ADRs in `docs/adr/`. Starting set:
  - git CLI vs libgit2 (§8.3)
  - custom diff view vs TextKit (§8.5)
  - observable models vs TCA
  - base detection algorithm (§5.1)

### 8.3 Git layer

- **Run the `git` CLI** (`/usr/bin/env git`, the user's own git) through a small async process
  runner. This means the user's config, `.gitattributes`, diff algorithms, worktrees and
  `includeIf` all behave exactly as they do in the terminal. libgit2 was rejected because its
  worktree, attribute and diff behaviour drifts from git's.
- Every command gets `-c core.quotepath=off`, `--no-pager`, `GIT_OPTIONAL_LOCKS=0` (reads must
  never take index locks while agents are writing), and `LC_ALL=C`.
- Output is parsed from porcelain and `-z` formats wherever they exist. The unified diff parser
  handles: renames and copies, binary markers, mode changes, `\ No newline at end of file`, and
  quoted and unicode paths.
- Full-file contents for highlighting and context expansion: one `git cat-file --batch` per diff
  load, fed every blob id the load needs (`--full-index` gives full ids). Working-tree files are
  read from disk. This keeps blob reads behind `GitClient`, so tests stay hermetic; a long-lived
  process would need its own seam for no measured gain.
- A first load shows the diff as soon as it's parsed and adds contents when they arrive. A
  reload swaps diff and contents together, so new hunks never meet the old file's lines.
- Cancellation: switching worktrees or scopes cancels in-flight processes for the old selection.

### 8.4 Syntax highlighting

- tree-sitter through SwiftTreeSitter, with the highlight queries bundled. v1 grammars: C#,
  TypeScript/TSX, JavaScript, JSON, YAML, Markdown, XML (csproj/props), Rust, TOML, Dockerfile.
  Other files show uncoloured; each grammar costs up to several MB of app size.
- Parse the **whole** old and new files, then map the highlights onto diff lines. Highlighting a
  single hunk gets multi-line strings and comments wrong.
- Highlighting runs off the main thread and is cached by language and content hash, which covers
  blobs and working-tree files alike. Lines are drawn without colours first, and colours appear
  when ready: the file being read first, the rest in batches. On a reload, a file whose text
  changed drops its old spans until it is highlighted again.
- Grammars are vendored as C targets under `Vendor/Grammars` by `Scripts/vendor-grammars.sh`,
  which pins each repository's ref and records the commit in `VERSIONS.md`. Only `parser.c`, the
  scanner, the headers, the highlight query and the licence are kept. Their C warnings are
  silenced (`-w`): generated third-party code isn't ours to fix, and the build stays clean.
- Where a vendored query misses common constructs, Seam's own patterns in
  `Sources/Highlighting/QueryAdditions/<language>.scm` are appended to it; the vendoring script
  doesn't touch them. C#: return types, calls without a receiver, generic calls, namespaces and
  `using` names.
- The token types (`SyntaxToken`, `SyntaxSpan`) live in SeamCore, so Highlighting produces them
  and DiffView draws them without either importing the other. Syntax colours are part of
  `DiffPalette`, contrast-tested on every diff background.
- Unknown language: plain text.

### 8.5 Diff rendering

This is where the project's performance risk lies.

- One custom `NSView` as the document view of an `NSScrollView`, drawing only visible rows with
  Core Text. Side-by-side mode draws both columns in the same view, so scrolling is synced by
  construction. There are no linked scroll views.
- Row model: a flat array of display rows (file header, hunk header, context, removed, added,
  paired, gap/expander), with prefix sums of row heights. Rows have a fixed height when wrapping
  is off. With wrapping on, a row's height follows from its length: the text is monospaced, so
  it wraps at a fixed column and needs no measuring. A width change recomputes heights and keeps
  the reader's line in view.
- Typesetting results (`CTLine`) are cached per row and theme, and the cache is dropped on width
  or font changes.
- Selection, copy, and find in the diff (`⌘F` while the diff has focus) are implemented on the
  row model, not on a text storage. `⌘F` with text selected in the diff starts the search from
  the selection's first line, selected in the field so typing replaces it.
- Rejected: a SwiftUI `LazyVStack` of `Text` (hitches beyond a few thousand rows, and selection is
  poor); one big `NSTextView` (side-by-side alignment and per-row decorations fight TextKit).

### 8.6 Live updates

- FSEvents watches each worktree directory, honouring `.gitignore` (events under ignored paths are
  dropped), and the repo's common git dir (`refs/`, `packed-refs`, `HEAD`, `worktrees/*/HEAD`,
  `index`).
- Events are coalesced: the first relevant event opens a 300 ms window, and everything arriving
  within it is delivered as one change. Unlike a trailing debounce, continuous writes can't
  postpone a reload indefinitely. Paths git ignores (`git check-ignore`) are dropped before they
  can open a window. A working-tree change refreshes that worktree's diff and counts, and
  a ref change re-runs base detection for every worktree in the repo.
- Hidden worktrees refresh only their row counts (cheap: `git status --porcelain=v2 -z` plus the
  cached unique-commit count). Only the selected worktree's full diff is recomputed.
- A reload keeps the scroll position anchored to the same file and line wherever possible.

### 8.7 Performance budgets

Measured on a real repository (347 refs, 20 worktrees):

| Operation | Budget |
|---|---|
| Base detection, one worktree | ≤ 150 ms |
| Worktree list ready on repo open (all rows with counts) | ≤ 1 s |
| Switching worktrees → first diff paint (≤ 5k diff lines) | ≤ 200 ms |
| First paint for a 20k-line diff | ≤ 500 ms (highlighting may arrive later) |
| Scrolling | no dropped frames at 120 Hz on a 20k-line diff |
| Idle CPU with 20 watched worktrees | ~0 |

## 9. UI/UX conventions

Follow Apple's Human Interface Guidelines for macOS. Where Seam deviates from them, the reason is
written down here.

**Structure**
- The window is a three-column `NavigationSplitView` (sidebar | content | detail). Column
  collapsing, resizing and the sidebar toggle all behave natively. `⌘\` is the one custom
  shortcut on top of that.
- Toolbar in the unified style, holding only: view mode, reload, and the thread panel (§7.7).
  The diff gets the rest of the window.
- Standard scenes: `WindowGroup` per repo, a `Settings` scene (`⌘,`), File › Open Recent and full
  screen. Window tabs are off, the one deviation here (§7.1). The workspace reopens the windows on
  relaunch, each in its repo's frame, and §11 state restores their selection.

**Commands and keyboard**
- **Every action is in the menu bar**, with its shortcut shown (File, Edit, View, Go, Review,
  Window, Help). This is how macOS users discover shortcuts. The command palette and single-key
  bindings supplement the menus and never replace them.
- `⌘`-shortcuts follow system conventions and never override standard ones (`⌘F` find, `⌘C`
  copy, `⌘+`/`⌘−` font size, `⌘W`, `⌘,`).
- Single-letter keys (§7.5) only work while the diff or file list has focus, and not while a
  sheet or popover is open. That's the same convention Mail and Xcode use for unmodified keys.
  They never fire inside a text field. AppKit lets a menu key equivalent win over a focused text
  field even when the item is disabled, so the menu items carry their single-letter shortcut
  only while it applies.
- Viewed toggles can be undone (`⌘Z`) through the window's `UndoManager`. They're the only state
  changes Seam makes.
- Full Keyboard Access works everywhere. Focus order: worktrees → files → diff.

**Appearance**
- Semantic system colours and the user's accent colour. Light and dark follow the system.
  Increase Contrast, Reduce Transparency and Reduce Motion are all honoured.
- Diff colours are defined in code (`DiffPalette`) with light, dark and high-contrast variants,
  not as asset catalog colours, because `swift build` doesn't compile asset catalogs. Text,
  markers and line numbers on every diff background must reach WCAG AA contrast (4.5:1), checked
  by a unit test against those values.
- **Colour is never the only signal:** added and removed lines also carry a `+` or `−` gutter
  marker, and file status shows as a letter.
- Monospaced font for code (default SF Mono), system font for all chrome.

**Feedback**
- No modal alerts for recoverable conditions. Use an inline banner at the top of the diff for a
  failed git command, a missing worktree directory, or a stale parent (§5.4), with an action
  button where one exists.
- Progress indicators appear only after 150 ms, so fast operations don't flicker. Stale content
  stays visible, dimmed, while a reload runs.
- Every empty state says why and what to do: "No changes against
  origin/feat/a", "Not a git repository — choose another folder".

**Accessibility**
- SwiftUI panes get VoiceOver support from the framework. Every control has a label, and each
  worktree row reads its counts as words.
- The custom diff view implements `NSAccessibility`: each visible row is an element ("added, new
  line 42: …"), hunks are groups, and VO navigation follows `n`/`p`.
- Strings live in a String Catalog per module. The app is English only, but nothing is
  hard-coded in views. `swift build` doesn't extract keys, so `make strings` syncs the catalogs
  from the Xcode build.

## 10. Testing strategy

Every layer gets the cheapest test that can catch its failures. Test names describe behaviour
("stacked branch that merged main picks the parent"), not methods.

| Layer | Kind | Framework | What it covers |
|---|---|---|---|
| GitKit parsers | Unit, golden files | Swift Testing | Real `git` outputs checked in under `Tests/Fixtures/`: renames, copies, binary files, mode changes, `\ No newline`, quoted and unicode paths, CRLF, empty files, porcelain v2 status, worktree porcelain with locked, prunable and detached entries |
| GitKit parsers | Round-trip property | Swift Testing, seeded generator | Generate random old/new file pairs, run real `git diff`, parse it, apply the parsed hunks to old → must equal new. 500 cases per run, with the seed printed on failure |
| SeamCore | Unit | Swift Testing, parameterised | Ranking and tie-breaks (§5.1) as a pure function, intra-line pairing, viewed-state invalidation, scope assembly, generated-file matching |
| Base detection | Integration, real git | Swift Testing | Fixtures F1–F14: the fixture builder (`Tests/TestSupport/FixtureRepo.swift`) creates each repo in a temp dir, with a local bare repo as `origin` so remote refs are real. The test asserts parent, base and file list. The ordinary path (F1) is tested as carefully as the edge cases |
| DiffView | Unit | Swift Testing | Row model: prefix sums, hit testing, selection ranges, scroll anchoring across reloads |
| DiffView | Image snapshot | swift-snapshot-testing | ~10 snapshots: unified/side-by-side × light/dark/high contrast, word highlights, wrapped rows. Recorded per macOS major version |
| Features | Unit | Swift Testing | Models driven through intents with fakes: switching worktrees cancels the old work, reloads keep the selection, banner states |
| Features | Window snapshot | swift-snapshot-testing | The window's panes rendered in-process from a fixture repo, light and dark: worktree rows, commit rows, file list with the diff, the welcome screen. Ages are measured from a fixed time. Sidebar rows render outside their List, because an off-screen render draws a sidebar's selection solid black. Needs no screen or automation permission |
| Features | Window layout | Swift Testing | Real `NSWindow`s that are never ordered on screen: a repo window's frame, content area and toolbar items don't change while the repo opens; a repo's window opens in its saved frame even though SwiftUI cascades it; frames save on move and resize once shown |
| App | UI smoke, run by hand | XCUITest | 5 flows on a fixture repo passed as a launch argument: open, `⌘2` switch, `j`/`n` navigation, `v` viewed + `⌘Z`, base override, plus windows and their frames. Automation Mode isn't left enabled, so `xcodebuild test` asks for approval each run |
| Performance | Benchmarks | XCTest `measure` with baselines | Detection on a generated repo with 400 refs, parsing and laying out a 20k-line diff. Fails on a >20% regression against the stored baseline. Baselines need `xcodebuild`, so until the Xcode project exists (M2) an opt-in Swift Testing check (`SEAM_BENCH=1`) asserts the absolute §8.7 budget |
| Real repo | Acceptance, opt-in | Swift Testing, gated by `SEAM_REAL_REPO` | The stacked-branch check from §5.2, configured in `local.mk` |

Rules:
- **Hermetic git:** every test that runs git sets `GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_CONFIG_NOSYSTEM=1`, and fixed author, committer and dates. Fixture commit SHAs are then
  stable and can appear in assertions.
- **A bug fix starts with a failing test.** Every misdetected base becomes a new F-fixture.
- **No sleeps:** time-dependent code (debounce, the 150 ms progress delay) takes a `Clock`, and
  tests use a manual clock.
- No coverage percentage target. The table above is the required coverage, and reviews check new
  code against it.
- `make check` runs everything except the opt-in and UI tests: format lint, build with warnings
  as errors, and `swift test`. `make test-all` adds `xcodebuild test` (UI tests and performance
  baselines). A pre-commit hook runs `make check`. If the repo goes to GitHub, a macOS Actions
  workflow runs `make test-all`.

**Commits:** Conventional Commits (`feat:`, `fix:`, `test:`, …), each one building and passing
`make check`.

## 11. Persistence

`~/Library/Application Support/Seam/`, as JSON:

- `repos.json`: recently opened repos (paths of common git dirs).
- `<repo-id>/state.json`, per repo:
  - Per branch: the base override (§5.3).
  - Per worktree: scope, scroll anchor, selected file.
  - **Viewed state:** keyed by (worktree path, file path), storing the blob id of the new side
    when it was marked viewed. If the file's content changes later, the viewed mark is cleared
    and the file is marked "changed since viewed".
- Settings live in `UserDefaults`.

Seam writes nothing inside the repository or `.git`.

## 12. Settings

- Default base ref (default: `origin/HEAD`, falling back to `origin/main`, then `main`).
- Ref ignore globs for detection (default: `origin/dependabot/**`, `origin/renovate/**`).
- Generated-file globs (§6.3).
- Editor command template (§7.6).
- Font and size (default: SF Mono 12). Tab width (default 4, or `.editorconfig` if present).
- View mode (unified or side by side), whitespace mode, and number of context lines.

Settings apply to the next load of each worktree; font changes apply at once (`⌘+`, `⌘−`, `⌘0`
in the View menu too). The default base may be a short name (`origin/develop`, `main`). Tab widths
come from the repository's root `.editorconfig` (`tab_width`, or a numeric `indent_size`) where a
section matches, else the setting; nested `.editorconfig` files aren't read.

## 13. CLI

The app bundle includes a `seam` command, installed via a menu item that symlinks it into
`~/.local/bin`:

```
seam                    # open the repo containing $PWD, select the worktree you're in
seam <path>             # same, for <path>
seam --base <ref>       # set the base override for this worktree, then open

seam threads [--all] [--json]          # this worktree's open threads (--all: resolved too)
seam thread <id> [--json]              # one thread with its comments
seam reply <id> <text>                 # answer a thread; reopens a resolved one
seam comment <file>:<line>[-<end>] [--old] <text>   # open a thread as the agent
seam resolve <id> | seam reopen <id>   # only for threads this author opened
```

Thread commands act on the worktree containing `$PWD` (or `-C <path>`) and sign as
`--as <name>`, else `$SEAM_AGENT`, else `agent`. They work without the app running; a running app
picks the change up from the file. Text output is for agents to read: each thread with its id,
file, lines, status, the quoted lines and the comments; `--json` gives the same structurally.
Exit status is non-zero, with a message on stderr, for an unknown id or a resolve the author
isn't allowed.

Opening talks to the running app through a URL scheme (`seam://open?path=…&base=…`), launching
the app if needed. The command is a Swift executable (swift-argument-parser) in the app's
resources, built from the `seam-cli` target on SeamCore; it resolves the path, percent-encodes it
and opens the URL with the app it belongs to: it follows its
own symlinks, and from `X.app/Contents/Resources/seam` runs `open -a X.app <url>`, because a
build-directory copy and an installed copy can coexist and `open -b` would pick whichever
LaunchServices prefers. Anywhere else it falls back to `open -b com.danielhedren.seam <url>`. The
URL reaches the key window: a window showing that repo selects the worktree (and applies `--base`
as its override), the welcome window becomes the repo's window, and any other window brings up
the repo's own. File › Install Command Line Tool… symlinks the command, so updating the app
updates it; it refuses to replace a file there that isn't its symlink. The app target builds the
command with `Scripts/build-cli.sh` (its own SwiftPM scratch path, then an ad-hoc signature,
because the app's signature doesn't cover code inside its resources). `SEAM_THREAD_DIR` points
the thread commands at another store, for trying them out.

### 13.1 Install and distribution

- `make install` builds Release, quits a running installed copy (relaunching it afterwards),
  copies `Seam.app` into `~/Applications` beside the old one and then swaps them, registers it
  with LaunchServices, and points `~/.local/bin/seam` at its script. The link rule is the menu
  item's: it replaces only a symlink to some `Seam.app`'s script and leaves anything else alone.
  It prints the installed path and version. `make uninstall` removes `~/Applications/Seam.app`
  and the link, if the link points at it.
- `make dist` writes `.build/dist/Seam-<version>-<build>.zip` (`ditto -c -k --keepParent`) to
  copy to another Mac. The app is ad-hoc signed and not notarized, so on another Mac Gatekeeper
  blocks the first launch: right-click › Open, or `xattr -d com.apple.quarantine Seam.app`.

## 14. Milestones

Each milestone ends with a version you can use daily.

**M1 — Core (headless).** The `SeamCore` package: process runner, worktree listing, base
detection, diff parsing, review-diff assembly. A debug CLI target that prints a worktree's parent,
base, and file list.
*Done when:* fixtures F1–F14 pass, the real-repo check passes, and detection meets the
§8.7 budget.

**M2 — Viewer MVP.** The three-pane window, worktree list with counts, file list, unified and
side-by-side views drawn without highlighting, keyboard navigation, scopes, the base picker,
live reload.
*Done when:* you can review a stacked branch end to end from the keyboard, and editing a file in that
worktree updates the diff within 1 s with no jump in scroll position.
*Left for later:* the XCUITest smoke flows, which need Automation Mode enabled on the machine.
Wrapping and find moved to M3; VoiceOver hunk groups were done in M4.

**M3 — Reading quality.** tree-sitter highlighting, word-level highlights, context expansion,
generated-file collapse, binary and image entries, line wrapping, find in the diff.
*Done when:* §8.7 rendering budgets are met on a 20k-line synthetic diff.

**M4 — Review state and polish.** Viewed state with invalidation, stale-parent banner, open in
editor, `seam` CLI, settings, command palette.

**M5 — Review threads (§7.7).** Thread model, anchoring and the shared store in SeamCore; the
`seam` command rewritten in Swift with the thread commands; threads in the diff and the thread
panel; Copy Prompt for Agent.
*Done when:* a reader can comment on a range, an agent in that worktree can list and answer it
with `seam`, the answer appears in the open app without a reload, and only the opener can
resolve.

**Later:** `gh` integration (PR status for the stale-parent check, PR number in
the worktree row).

## 15. Risks

| Risk | Mitigation |
|---|---|
| Custom text rendering (selection, copy, find; no editing, so no IME) takes longer than planned | Start M2 with the custom view right away. It's the one part that's expensive to replace later. Selection and copy are in M2 scope, not deferred. |
| Detection chooses the wrong parent in cases not covered by fixtures | The header always shows the parent, override takes one click, and every misdetection becomes a new fixture. |
| tree-sitter grammar or query packaging friction in SwiftPM | Vendor grammars as C targets. Highlighting comes in M3, so the MVP doesn't depend on it. |
| FSEvents load from `node_modules`/`bin`/`obj` churn during builds in many worktrees | Drop ignored paths before debouncing. Refresh hidden worktrees' counts at most every 5 s. |

## 16. Open questions

None.

Decided (2026-10-21): a local parent's unpushed commits count as the base (§5.1); one window per
repo (§7.1); the name is Seam; viewed marks survive a rebase for files whose content is unchanged (§11).
