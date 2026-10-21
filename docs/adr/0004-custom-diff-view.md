# 4. Draw the diff in a custom AppKit view

Status: accepted (2026-10-21)

## Context

Diffs of 20k+ lines must scroll at 120 Hz, side-by-side columns must stay aligned, and rows carry
decorations (gutters, word highlights, expanders) that text systems don't model.

## Decision

One `NSView` inside an `NSScrollView` draws only the visible rows with Core Text from a flat row
model with prefix-summed heights. Both columns are drawn by the same view, so scrolling is synced
by construction. Selection, copy, find and `NSAccessibility` are implemented on the row model.

## Consequences

- Meets the SPEC §8.7 budgets with predictable cost per visible row.
- Selection, find and accessibility are our code to write and test; they are in M2 scope, not
  deferred.
- Rejected: SwiftUI `LazyVStack` of `Text` (hitches past a few thousand rows, weak selection) and a
  single `NSTextView` (alignment and per-row decoration fight TextKit).
