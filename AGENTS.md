# Seam — rules for every agent and contributor

Seam is a native macOS diff viewer for reviewing worktrees. `SPEC.md` is the source of truth for
behaviour, architecture, UI conventions and testing. These rules are binding. If a rule and the
spec disagree, stop and ask; do not pick one silently.

## Before you start

- Read `SPEC.md` §5 (base detection), §8 (technical design), §9 (UI/UX) and §10 (testing) before
  touching code in those areas. Read the ADRs in `docs/adr/` that cover the module you change.
- Work only on the current milestone (§14). Anything outside it needs the user's go-ahead.
- Changing behaviour the spec defines means changing the spec in the same commit, and an ADR
  when a §8 decision changes.

## Toolchain

- Swift 6.4, Swift 6 language mode, complete strict concurrency, warnings are errors. Minimum
  macOS 26, Apple silicon.
- `make check` must pass before every commit: format lint, build, `swift test`. Run `make setup`
  once per clone to install the pre-commit hook. Never bypass it with `--no-verify`.
- `make format` rewrites files with `swift format`. Don't hand-format against it.
- No new dependency without the user's approval. Allowed today: SwiftTreeSitter + grammars,
  swift-argument-parser, swift-snapshot-testing (tests only). Pin exact versions.

## Architecture (SPEC §8.2)

- Module dependencies point downward only:
  `SeamApp → Features → DiffView / Highlighting → SeamCore → GitKit`. Never import upward or
  sideways. `seam-debug` may use `SeamCore` and `GitKit`.
- **Functional core, imperative shell.** Parsing, detection ranking, diff assembly, layout and
  viewed-state logic are pure functions over value types. I/O (processes, files, FSEvents,
  persistence) lives at the edges behind protocols.
- Injection through initialisers with protocols (`GitClient`, `FileSystem`, `FileWatcher`,
  `Clock`, `Store`). No singletons, no global mutable state, no DI framework.
- Concurrency: structured concurrency and actors. No `DispatchQueue` in new code except where an
  Apple API requires it. No blocking I/O on the main actor. `@unchecked Sendable` only around a
  non-Sendable Apple type, with a one-line comment saying why it is safe.
- Errors: typed domain errors (`throws(GitError)` etc.) where the set is closed. No `fatalError`,
  `try!`, force unwraps or `precondition` on paths that real input can reach.
- Logging via `os.Logger` (subsystem `com.danielhedren.seam`, category = module). Signpost every
  operation that has a §8.7 budget. No `print` outside `seam-debug`.
- Git: always the `git` CLI through `GitClient`. Pass every option whose user config would change
  the output (prefixes, colour, renames, algorithm, context, textconv). Seam never writes to the
  repository, the index or `.git`.

## UI (SPEC §9)

- Apple HIG for macOS. Every action lives in the menu bar with its shortcut. Single-letter keys
  only when the diff or file list has focus. No modal alerts for recoverable errors.
- Semantic system colours; colour is never the only signal. Every control has an accessibility
  label. User-facing strings go in the String Catalog.

## Testing (SPEC §10)

- A bug fix starts with a failing test. A misdetected base becomes a new fixture in §5.2.
- Test the ordinary success path, not only failures and edge cases.
- Hermetic git in tests: `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, fixed author,
  committer and dates. Use the fixture builder `FixtureRepo` in `Tests/TestSupport/`.
- No sleeps. Anything time-based takes a `Clock`.
- Swift Testing (`@Test`, `#expect`, `#require`) for everything except performance baselines and
  UI tests (XCTest). Name tests after behaviour.
- A test that passes before and after the change it is meant to prove is not evidence. Check that
  new tests fail without the change.

## Code style

- Follow the surrounding code: naming, idiom, comment density.
- Comments explain *why*, never *what*. Inline comments 1–2 lines, type comments ≤ 15 lines, and
  no more than ~10% of a file's lines. No history narration ("previously…", "this replaces…").
- `public` only for what another module uses.

## Commits

- Conventional Commits (`feat:`, `fix:`, `test:`, `refactor:`, `docs:`, `chore:`), imperative,
  one logical change each, every commit passing `make check`.
- Never add AI attribution: no `Co-Authored-By` trailers for agents, no "Generated with" lines.
- Don't push, add remotes or create GitHub repos unless the user asks.
