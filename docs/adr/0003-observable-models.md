# 3. Observable models, not TCA

Status: accepted (2026-10-21)

## Context

The app has one main screen (worktrees | files | diff) per window, one developer, and most logic
already lives in pure functions in `SeamCore`.

## Decision

Use `@Observable` models owned per window (`RepoSession`, `WorktreeReview`), with views calling
intent methods and data flowing services → models → views. Long-lived work runs in actors.

## Consequences

- No third-party architecture dependency, fast compiles, idiomatic SwiftUI.
- Discipline replaces framework enforcement: models stay thin, logic goes into `SeamCore` where it
  is unit-tested. TCA was rejected for its dependency weight and compile-time cost at this scale.
