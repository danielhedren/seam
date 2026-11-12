# Tech debt

Oddities met while working on something else, left as they were. One entry each: where, what's
odd, why it matters, and a suggested fix. Line numbers are from when the entry was written.

## ReviewModel

- `Sources/ReviewModel/CommandCatalog.swift:15` — `shortcutLabel(of:)` carries two doc comments
  run together; the first ("A tooltip ending in the command's shortcut…") describes `help`
  below it. Readers get the wrong description for both. Move the first two lines down to `help`.
- `Sources/ReviewModel/WorktreeReview.swift:133`, `Sources/ReviewModel/RepoSession.swift:87` —
  the logger and signposter use category `Features`, the module these types lived in before
  ReviewModel was split out; so do `StateStore.swift:28` and `RepoPullRequests.swift:85`.
  AGENTS.md says category = module, and console filters by module miss them. Rename to `ReviewModel` (and check Instruments templates that name the category).
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
- `Sources/ReviewModel/StateStore.swift:163` — `SeamServices.platform` is a `var`, and tests
  replace it after the services are built (`services.platform = platform`). Anything built in
  `SeamServices.init` that keeps the platform (as the notification bell of SPEC §7.10 will)
  goes on talking to the first one. Fix: pass the platform when the services are built
  (`services(_:platform:)` in `Tests/ReviewTestSupport/Session.swift` now takes one) and make
  the property a `let`.
- `Sources/ReviewModel/RepoSession.swift:277` — `select(_:)` serves both the reader's pick and
  the restore of the last selection in `open()`. Whoever needs to tell them apart must add a
  flag, as `notesOpens` does. Fix: a private `show(_:)` both call, with `select` the reader's.
- `Sources/ReviewModel/RepoSession+Notifications.swift:108` — `NotificationText` writes
  notification ids as `<worktree>|<what>` strings, and `NotificationSubject`
  (`Sources/SeamCore/NotificationSubject.swift:12`) matches them by prefix. The two can drift,
  and a listed pull request's id is told from the main worktree's only by `pr-`. Fix: a typed
  id in SeamCore that both write and match.
- `Sources/ReviewModel/RepoSession+Notifications.swift:168` — `NotificationText.notification`
  has a case for `.reviewRequested` and `.newPullRequest` that is never reached, since
  `listed(_:repo:)` takes them first. Fix: split the event type so the switch needn't cover
  them.
- `Sources/ReviewModel/SeamCommand.swift:79` — every command runs on a `RepoSession`, so the
  menus are off in the welcome window even for commands about the whole app (the bell's will
  be). Fix: let a command say it needs no session.

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
- `Tests/TestSupport/FixtureRepo.swift` — a `FixtureRepo` removes its folder when it's
  released, so a helper that returns only the session leaves the session on a deleted repo and
  the test times out with no hint why. Fix: say so on the type, or have helpers return it.
- `Scripts/prove-test.sh:36` — `make prove` is inconclusive for any test that uses API the
  change adds, which is most new features. Fix: none cheap; mutation by hand meanwhile.

## Features

- `Sources/Features/RepoSpotlight.swift:50` — `SeamAppDelegate` is made by
  `@NSApplicationDelegateAdaptor` with no services, so it can reach nothing injected: a
  clicked notification can only be sent on as a URL. The bell needs it to report the clicked
  id. Fix: have `SeamScenes` take the delegate and hand it what it needs.
- `Sources/Features/MacPlatform.swift:13` — `open(_:)` sends a `seam://` URL to whichever app
  LaunchServices has for the scheme, while the delegate's `send` pins it to this bundle
  (`RepoSpotlight.swift:53`). With two copies of Seam installed they can differ. Fix: pin
  `seam://` in `MacPlatform.open` and have the delegate use it.
