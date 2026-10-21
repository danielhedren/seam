# 2. Detect the parent branch from the commit graph

Status: accepted (2026-10-21)

## Context

The review diff must start where the branch left its parent. `merge-base origin/main HEAD` is wrong
for stacked branches (feat/b: 67 files instead of 19). Branch metadata (upstream, reflog
"Created from") is unreliable: upstreams get reset by `push -u`, and worktrees are often created
with `--no-track`.

## Decision

Use the commit graph: the parent is the ref that lacks the fewest of HEAD's commits, found from the
boundary of `rev-list HEAD ^<all other refs>` (SPEC §5.1). Refs that contain HEAD are descendants
and excluded. The only place the graph is ambiguous — another ref at HEAD's exact commit — is
settled by remote-ness, the default base, the upstream, and reflog creation order.

## Consequences

- Correct for every shape in SPEC §5.2 (F1–F12) in a handful of git calls; ~150 ms on a repo with
  347 refs.
- A stacked branch that merged a newer main than its parent has no single correct base; Seam picks
  the ref with the fewest missing commits and the user can override it.
- A squash-merged parent stays the parent until its refs are deleted (§5.4 warns about it).
- Every misdetection found in use becomes a new fixture.
