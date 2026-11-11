# Tech debt

Oddities met while working on something else, left as they were. Each has where it is, what's
odd, why it matters and a suggested fix.

## ReviewModel

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
- `Sources/ReviewModel/RepoSession.swift:87` — the session logs under category `Features`
  though it lives in `ReviewModel` (AGENTS.md: category = module); `StateStore.swift:28` and
  `RepoPullRequests.swift:85` do the same. Fix: rename the categories.

## Features

- `Sources/Features/RepoSpotlight.swift:50` — `SeamAppDelegate` is made by
  `@NSApplicationDelegateAdaptor` with no services, so it can reach nothing injected: a
  clicked notification can only be sent on as a URL. The bell needs it to report the clicked
  id. Fix: have `SeamScenes` take the delegate and hand it what it needs.
- `Sources/Features/MacPlatform.swift:13` — `open(_:)` sends a `seam://` URL to whichever app
  LaunchServices has for the scheme, while the delegate's `send` pins it to this bundle
  (`RepoSpotlight.swift:53`). With two copies of Seam installed they can differ. Fix: pin
  `seam://` in `MacPlatform.open` and have the delegate use it.

## Tests

- `Tests/TestSupport/FixtureRepo.swift` — a `FixtureRepo` removes its folder when it's
  released, so a helper that returns only the session leaves the session on a deleted repo and
  the test times out with no hint why. Fix: say so on the type, or have helpers return it.
- `Scripts/prove-test.sh:36` — `make prove` is inconclusive for any test that uses API the
  change adds, which is most new features. Fix: none cheap; mutation by hand meanwhile.
