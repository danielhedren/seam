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

`git merge-base origin/main HEAD` doesn't solve this for stacked branches. Measured on
`work-repo`, worktree `feat-b`:

| Base | Commits | Diff |
|---|---|---|
| `merge-base origin/main HEAD` | 17 | 67 files, +1123 −1160 |
| actual parent `origin/feat/a` (`4a1b2c3d4`) | 5 | 19 files, +454 −948 |

feat/b is stacked on feat/a, and feat/a has merged main twice. Diffing against main pulls
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
- Agent notes, comments, or a session API (hunk's agent integration). Not needed now. §13 keeps
  the design from ruling it out later.
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
`seam-debug`. Boundary `4a1b2c3d4` is contained only by `feat/a-local` and
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
| F4 | Stacked, where B has merged main since C branched (the feat/b shape) | B; base = merge-base(B, C) |
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

Plus one real-repo check: on `feat-b`, commit `9f8e7d6c5` reviewed as
`feat/b` must pick `origin/feat/a` and give a
committed-scope diff of 19 files, +456 −950. (Plain `git diff --shortstat` says +454 −948; the
difference is Seam's `--histogram`.) The branch has since been rebased onto main, so the check
pins the commit and stops working once that parent ref is deleted.

### 5.3 Overrides

- The diff header shows the chosen parent ("vs origin/feat/a · 5
  commits"). Clicking it opens a picker listing all candidates with their commit counts, plus
  "Choose ref or commit…".
- A manual choice is saved per repo and branch (§11) and wins over detection until it's cleared.
  If the saved ref disappears, fall back to detection and show a notice.

### 5.4 Stale parent

If the parent has been squash-merged, its commits never reach main. Detection then keeps choosing
the old parent, and the diff shows only the commits after it. Signals:

- The parent's remote ref is `[gone]` after a fetch. The local branch may still exist.
- The parent is a local branch with no remote ref, and it is fully contained in another candidate.

On either signal, show a non-blocking banner: "Parent `X` looks merged — diff against `origin/main`
instead?" Asking `gh` whether the PR is merged is out of scope for v1.

### 5.5 Fetching

Seam reads whatever refs are local. It does not fetch by default. A toolbar action and the `f`
key run `git fetch --prune` for the current repo. Background fetching on an interval is an option
(off by default).

## 6. The review diff

### 6.1 Contents

For a worktree with base `M`:

- **Tracked changes:** `git diff --no-ext-diff --no-color --histogram -M -C --find-renames <M>`.
  This includes committed, staged and unstaged changes.
- **Untracked files:** `git ls-files --others --exclude-standard`, each shown as a full addition.
  Seam never runs `git add -N`, because it must not modify the index.

### 6.2 Scopes

A segmented control picks the scope (keys `1`/`2`/`3` when the diff has focus):

| Scope | Range | Default |
|---|---|---|
| **All** | base → working tree (+ untracked) | ✓ |
| **Committed** | base → HEAD | |
| **Uncommitted** | HEAD → working tree (+ untracked) | |

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
│ work-repo       │ 19 files +454 −948│ vs origin/feat/a · 5 commits ▾│
│ ● feat-b  ◆ │ ▾ src/Orders.Svc   │ [All|Committed|Uncommitted]  ⇆  ≡      │
│   +5  ✎2  2m           │   M Delivery…cs ✓ │                                        │
│ ● feat-a      │   M Options.cs    │  (side-by-side or unified diff)        │
│   +12      1h          │ ▾ contracts/…     │                                        │
│ ○ main                 │   M openapi.yaml  │                                        │
│ ○ old-spike-a  stale │ ▸ Generated (3)   │                                        │
└────────────────────────┴───────────────────┴────────────────────────────────────────┘
```

- Three panes: worktrees | files | diff. `⌘\` hides or shows both sidebars, `⌘⌥\` only the
  worktree list. Pane widths are remembered.
- One window per repo, listing only that repo's worktrees. Opening another repo opens another
  window (standard tabs work).
- Dark and light themes, following the system.

### 7.2 Worktree list

Each row shows:
- The worktree directory name in bold, and the branch name if it differs.
- `+N` commits unique to the branch (from §5), and `✎N` uncommitted files.
- Time since the last file change in that worktree (from the watcher).
- State markers: detached, locked, prunable (from porcelain output), missing directory, stale
  parent (§5.4).
- `◆` marks the selected worktree.

Sorting: most recently changed first (default), or by name. The main worktree is pinned to the
top. Worktrees whose directory is missing are listed dimmed, and can be hidden.

Switching: `⌘1`…`⌘9` pick by position, `⌘[`/`⌘]` go to the previous or next worktree, and `⌘K`
opens fuzzy search over worktree and branch names. Each worktree keeps its own scroll position,
selected file, and scope.

### 7.3 File list

- A tree grouped by directory with single-child directories compacted (`src/Orders.Service/…`),
  or a flat list (toggle). Status letter (A/M/D/R/C), `+/−` counts, and a viewed checkmark per
  file.
- The header shows totals and the viewed count ("7/19 viewed").
- Filter field (`⌘F` while the file list has focus) matching on path.
- Selecting a file scrolls the diff to it. The diff is one continuous scroll of all files, and
  the file list follows the scroll position.

### 7.4 Diff view

- Side-by-side and unified modes (`⇆` toggles, key `s`). The setting is global and can be
  overridden per worktree.
- A sticky file header per file: path, status, counts, viewed checkbox, a collapse toggle, and
  "Open in editor".
- Syntax highlighting (§8.4).
- **Word-level highlights within changed lines:** pair removed and added lines inside a hunk by
  similarity, then highlight the changed tokens. Unpaired lines get no word highlights.
- **Expanding context:** each gap between hunks has controls for "↑ 20 lines", "↓ 20 lines" and
  "all". These use the full file contents from the base and the working tree.
- Line numbers for both sides. Line wrapping is off by default (toggle `w`). Without wrapping,
  unified mode scrolls horizontally; split mode keeps each side at half the width and clips long
  lines at the column edge, so both sides stay in view.
- Text selection and copy work in both modes. In side-by-side mode a selection stays within one
  side.
- Hunk header context (function name), as git shows it.

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
| `x` | collapse / expand the current file |
| `o` | open the current line in the editor |
| `b` | base picker |
| `f` | fetch |
| `r` | force reload |
| `⌘\` | toggle sidebars |
| `⌘K` | worktree switcher |
| `⌘⇧P` | command palette (every action) |

### 7.6 Open in editor

Configurable command template. Default: `zed {path}:{line}`. Presets for VS Code
(`code -g {path}:{line}`) and Rider. `{path}` is the path inside the worktree being reviewed, so
the file opens in that worktree.

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
  project contains only the app entry point, assets, entitlements and signing, so merges never
  touch `project.pbxproj` for code changes.

### 8.2 Architecture

**Functional core, imperative shell.** Git output parsing, base detection ranking, review-diff
assembly, intra-line diffing, row layout and viewed-state invalidation are pure functions over
value types. Processes, file watching, persistence and UI sit around them and call in. This makes
nearly all of the logic testable without git or a window.

**Modules** (SwiftPM targets). Dependencies only point downward, and the compiler enforces it:

```
SeamApp (app target: SwiftUI scenes, menus, settings)
  └ Features      @Observable models + SwiftUI views per pane
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
- Full-file contents for highlighting and context expansion: `git cat-file --batch`, one long-lived
  process per repo, fed blob ids. Working-tree files are read from disk.
- Cancellation: switching worktrees or scopes cancels in-flight processes for the old selection.

### 8.4 Syntax highlighting

- tree-sitter through SwiftTreeSitter, with the highlight queries bundled. v1 grammars: C#,
  TypeScript/TSX, JavaScript, JSON, YAML, Markdown, XML (csproj/props), Swift, Rust, Bash, SQL,
  TOML, Dockerfile.
- Parse the **whole** old and new files, then map the highlights onto diff lines. Highlighting a
  single hunk gets multi-line strings and comments wrong.
- Highlighting runs off the main thread and is cached by blob id (and by mtime and size for
  working-tree files). Lines are drawn without colours first, and colours appear when ready.
- Unknown language: plain text.

### 8.5 Diff rendering

This is where the project's performance risk lies.

- One custom `NSView` as the document view of an `NSScrollView`, drawing only visible rows with
  Core Text. Side-by-side mode draws both columns in the same view, so scrolling is synced by
  construction. There are no linked scroll views.
- Row model: a flat array of display rows (file header, hunk header, context, removed, added,
  paired, gap/expander), with prefix sums of row heights. Rows have a fixed height when wrapping
  is off. With wrapping on, heights are measured lazily and cached per width.
- Typesetting results (`CTLine`) are cached per row and theme, and the cache is dropped on width
  or font changes.
- Selection, copy, and find in the diff (`⌘F` while the diff has focus) are implemented on the
  row model, not on a text storage.
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

Measured on `work-repo` (347 refs, 20 worktrees):

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
- Toolbar in the unified style, holding only: base picker, scope control, view mode, fetch. The
  diff gets the rest of the window.
- Standard scenes: `WindowGroup` per repo, a `Settings` scene (`⌘,`), File › Open Recent, native
  window tabs and full screen. Windows and their selection are restored on relaunch
  (`SceneStorage` plus §11 state).

**Commands and keyboard**
- **Every action is in the menu bar**, with its shortcut shown (File, Edit, View, Go, Review,
  Window, Help). This is how macOS users discover shortcuts. The command palette and single-key
  bindings supplement the menus and never replace them.
- `⌘`-shortcuts follow system conventions and never override standard ones (`⌘F` find, `⌘C`
  copy, `⌘+`/`⌘−` font size, `⌘W`, `⌘,`).
- Single-letter keys (§7.5) only work while the diff or file list has focus. That's the same
  convention Mail and Xcode use for unmodified keys. They never fire inside a text field.
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
- Strings live in a String Catalog. The app is English only, but nothing is hard-coded in views.

## 10. Testing strategy

Every layer gets the cheapest test that can catch its failures. Test names describe behaviour
("stacked branch that merged main picks the parent"), not methods.

| Layer | Kind | Framework | What it covers |
|---|---|---|---|
| GitKit parsers | Unit, golden files | Swift Testing | Real `git` outputs checked in under `Tests/Fixtures/`: renames, copies, binary files, mode changes, `\ No newline`, quoted and unicode paths, CRLF, empty files, porcelain v2 status, worktree porcelain with locked, prunable and detached entries |
| GitKit parsers | Round-trip property | Swift Testing, seeded generator | Generate random old/new file pairs, run real `git diff`, parse it, apply the parsed hunks to old → must equal new. 500 cases per run, with the seed printed on failure |
| SeamCore | Unit | Swift Testing, parameterised | Ranking and tie-breaks (§5.1) as a pure function, intra-line pairing, viewed-state invalidation, scope assembly, generated-file matching |
| Base detection | Integration, real git | Swift Testing | Fixtures F1–F14: the fixture builder (`Tests/SeamCoreTests/Support/`) creates each repo in a temp dir, with a local bare repo as `origin` so remote refs are real. The test asserts parent, base and file list. The ordinary path (F1) is tested as carefully as the edge cases |
| DiffView | Unit | Swift Testing | Row model: prefix sums, hit testing, selection ranges, scroll anchoring across reloads |
| DiffView | Image snapshot | swift-snapshot-testing | ~10 snapshots: unified/side-by-side × light/dark/high contrast, word highlights, wrapped rows. Recorded per macOS major version |
| Features | Unit | Swift Testing | Models driven through intents with fakes: switching worktrees cancels the old work, reloads keep the selection, banner states |
| App | UI smoke | XCUITest | 5 flows on a fixture repo passed as a launch argument: open, `⌘2` switch, `j`/`n` navigation, `v` viewed + `⌘Z`, base override |
| Performance | Benchmarks | XCTest `measure` with baselines | Detection on a generated repo with 400 refs, parsing and laying out a 20k-line diff. Fails on a >20% regression against the stored baseline. Baselines need `xcodebuild`, so until the Xcode project exists (M2) an opt-in Swift Testing check (`SEAM_BENCH=1`) asserts the absolute §8.7 budget |
| Real repo | Acceptance, opt-in | Swift Testing, gated by `SEAM_REAL_REPO` | The feat/b check from §5.2 |

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
  - Per worktree: scope, view mode, scroll anchor, selected file.
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
- Background fetch interval (off by default).
- Default view mode, whitespace mode, and number of context lines.

## 13. CLI

The app bundle includes a `seam` command, installed via a menu item that symlinks it into
`~/.local/bin`:

```
seam                    # open the repo containing $PWD, select the worktree you're in
seam <path>             # same, for <path>
seam --base <ref>       # set the base override for this worktree, then open
```

It talks to the running app through a URL scheme (`seam://open?path=…&base=…`), launching the app
if needed.

Later, not in v1: if agent notes are ever wanted, the same entry point can grow a local socket
API, as hunk has. Nothing in v1 depends on it.

## 14. Milestones

Each milestone ends with a version you can use daily.

**M1 — Core (headless).** The `SeamCore` package: process runner, worktree listing, base
detection, diff parsing, review-diff assembly. A debug CLI target that prints a worktree's parent,
base, and file list.
*Done when:* fixtures F1–F14 pass, the feat/b real-repo check passes, and detection meets the
§8.7 budget.

**M2 — Viewer MVP.** The three-pane window, worktree list with counts, file list, unified and
side-by-side views drawn without highlighting, keyboard navigation, scopes, the base picker,
live reload.
*Done when:* you can review feat/b end to end from the keyboard, and editing a file in that
worktree updates the diff within 1 s with no jump in scroll position.

**M3 — Reading quality.** tree-sitter highlighting, word-level highlights, context expansion,
generated-file collapse, binary and image entries.
*Done when:* §8.7 rendering budgets are met on a 20k-line synthetic diff.

**M4 — Review state and polish.** Viewed state with invalidation, stale-parent banner, fetch, open
in editor, `seam` CLI, settings, command palette.

**Later:** background fetch, `gh` integration (PR status for the stale-parent check, PR number in
the worktree row), agent notes API.

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
