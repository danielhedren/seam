# Tech debt

Oddities met while working on something else, left as they were. One entry each: where, what's
odd, why it matters, and a suggested fix. Line numbers are from when the entry was written.

## ReviewModel

- `Sources/ReviewModel/CommandCatalog.swift:15` — `shortcutLabel(of:)` carries two doc comments
  run together; the first ("A tooltip ending in the command's shortcut…") describes `help`
  below it. Readers get the wrong description for both. Move the first two lines down to `help`.
- `Sources/ReviewModel/WorktreeReview.swift:133`, `Sources/ReviewModel/RepoSession.swift:87` —
  the logger and signposter use category `Features`, the module these types lived in before
  ReviewModel was split out; AGENTS.md says category = module. Console filters by module miss
  them. Rename to `ReviewModel` (and check Instruments templates that name the category).
- `Sources/ReviewModel/CommandCatalog.swift:432` — `openThread` and `selectedGitHubThread` repeat
  the same `placedThreads.first { $0.id == id }?.thread` lookup. Two places to change when
  threads get another source. Build the second on the first.
- `Sources/ReviewModel/FindState.swift:45` — the first match a typed query scrolls to comes
  from `DiffScrollView.search`, not from `move(by:)`, so anything that must happen on "a find
  jump" has two entry points (Back and Forward needed `onQueryChange(started:)` for it). Give
  find one `reveal` path the session can observe.
- `Sources/ReviewModel/HighlightPass.swift:9` — `files` is `package`, its sibling properties
  internal, and nothing outside the module reads it. Misleads about what the module exports.
  Make it internal.

## DiffModel

- `Sources/DiffModel/DiffContent.swift:44` — the initialiser takes half of the properties
  (`resolvedMarks`, `preamble`, `showsReturns` are set afterwards by callers) and assigns them
  in an unrelated order. Easy to forget a field when building content in a test. Either take
  everything with defaults, or split "what the diff is" from "how it's shown".
- `Sources/DiffModel/DiffContent.swift:86` — `GapExpansion.all` is `top: Int.max / 2`, a magic
  number callers must not add to carelessly (`expand` adds 20 to it for `.down`). An enum
  (`.lines(top:bottom:)` / `.all`) would say it.
- `Sources/DiffModel/DiffLayout.swift:137` — `nextStop` and `previousStop` scan every row on
  each `n`/`p`/`j`/`k`. Fine at 20k rows today, but it is the only O(rows) work per keypress.
  Keep the stops' row indices when the layout is built.

## DiffView

- `Sources/DiffView/DiffScrollView.swift:98` — the view reads `NSWorkspace.shared` directly for
  Increase Contrast, with `increaseContrastOverride` as the test seam. It's the one place the
  diff view reaches a global; an injected value would drop the override.
- `Sources/DiffView/DiffHeaderDrawing.swift:41` — `layout` is recomputed (Core Text lines and
  all) for every draw, hit test and tooltip of a header. Cheap per header, but the sticky header
  redraws while scrolling. Cache by the inputs.

## Tests

- `Tests/FeaturesTests/Support.swift:29` — `runLoopOnce` has two doc comments with `@MainActor`
  between them; the second one describes `runLoop(for:)` below. Move it there.
- `Tests/FeaturesTests/Support.swift:20` — `showDiff` shows the content once and never again, so
  a test that changes the model must call `view.show` by hand (as `SearchViewTests` does) and
  can pass while `DiffShown` misses a field. Prefer `CardWindow`, or have `showDiff` observe.
