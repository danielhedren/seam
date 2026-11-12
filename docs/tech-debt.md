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
- `Sources/ReviewModel/StateStore.swift:163` — `SeamServices.platform` and `settings` are
  `var`s, and tests replace them after the services are built (`services.platform = platform`).
  Anything built in `SeamServices.init` that kept either would go on talking to the first one,
  so `NotificationBell` takes the platform with every call (`on:`) and is told the Dock switch
  by each session and window. Fix: pass both when the services are built
  (`services(_:platform:)` in `Tests/ReviewTestSupport/Session.swift` takes a platform), make
  the properties `let`, and let the bell keep them.
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
  menus are off in the welcome window even for commands about the whole app (the bell's
  three are; its toolbar button works there). Fix: let a command say it needs no session.
- `Sources/ReviewModel/NotificationBell.swift:15` — `JSONNotificationLogStore` repeats
  `JSONStateStore`'s decode, move-aside and atomic write (`StateStore.swift:36`, `:129`). Two
  places to change how Seam guards its files. Fix: one JSON file helper both use.
- `Sources/ReviewModel/RepoSession+Notifications.swift:30` — `noteOpened` clears
  notifications twice over: the bell removes what its log says was posted, then a task asks
  Notification Center what's delivered and removes what the subject covers. The second only
  matters for notifications the log has dropped. Fix: drop it once the log is trusted, or have
  the bell do both.
- `Sources/ReviewModel/NotificationBell.swift:70` — the log's dates come from a `now` closure
  while the rest of the model reads `Date.now` directly and takes only a `Clock` for waits.
  Fix: a wall clock in `SeamServices` that everything dated uses.

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
- `Tests/ReviewTestSupport/Session.swift:538` — `threadSession` builds its services by hand
  with the fixture's git, not through `services(_:)`, so its sessions skip `ReadOnlyGit` and
  can't take a bell, store or GitHub. AGENTS.md has session tests run git through
  `ReadOnlyGit`. Fix: build on `services(_:)` and pass its arguments through.
- `Scripts/prove-test.sh:36` — `make prove` is inconclusive for any test that uses API the
  change adds, which is most new features. Fix: none cheap; mutation by hand meanwhile.

## Features

- `Sources/Features/SeamScenes.swift:104` — `SeamScenes.init` sets the delegate's `clicked`
  closure, and runs on every evaluation of the app's body. Harmless, but the delegate still
  gets its services by assignment after it's made. Fix: build the delegate's closures once,
  where the services are built.
- `Sources/Features/BellButton.swift:12` — the bell is a `Toggle` with a popover on it, like
  no other toolbar item here. A click on it while the popover shows may close the popover and
  open it again (the popover closes on mouse down, the toggle flips on mouse up); not checked
  in a running app. Fix: check, and if so ignore the click that follows a dismissal.
