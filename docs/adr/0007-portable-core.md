# 7. A portable core below the UI

Status: accepted (2026-10-26)

## Context

Seam's logic sits partly in AppKit and SwiftUI modules: the diff's row model and layout in
`DiffView`, the observable models in `Features`. Below them, `GitKit`, `SeamCore` and
`Highlighting` use `os`, `CryptoKit`, FSEvents and Application Support, which exist only on
Apple platforms. A Linux build of the non-UI targets (portability review, 2026-10-26) hit six
such points and nothing deeper.

## Decision

Every module below the UI builds and passes its tests on Linux, checked by `make linux-check`.
`DiffModel` takes the UI-free half of `DiffView`; `ReviewModel` takes the models of `Features`.
Platform services (clipboard, opening, revealing, file watching, logging, state location) sit
behind protocols or small wrappers chosen per platform. `swift-crypto` replaces `CryptoKit`.
The app itself stays macOS only.

## Consequences

The models and their tests no longer need AppKit, a window or a Mac, and the compiler keeps UI
types out of them. A Linux client becomes possible, but none is planned. Two module boundaries
are added, and the Linux check is one more gate to keep green. File watching has two
implementations to test.
