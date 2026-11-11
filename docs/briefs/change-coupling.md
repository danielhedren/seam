# Brief: files that change together (change coupling)

Raised 2026-11-11, not yet designed or scheduled. Pairs with the authorship brief
(`authorship-signals.md`): both mine the main branch's history, so they can share one pass.

## Idea
Learn which files usually change together, from the history of the main branch, and use it in
two ways:

1. **Grouping:** clusters of files that change together, often across folders (a handler, its
   validator, its test, the contract file), as a way to group a review or map regional
   hotspots, which the folder tree doesn't show.
2. **Heads up:** when a change touches some of a group but not the rest: "`OrderHandler.cs`
   changed with `OrderValidator.cs` in 8 of the 10 commits that touched it; this change
   doesn't touch it." Stated as that fact, never as a verdict (SPEC §16: facts, not scores).

## Prior work
- Zimmermann et al. 2004, "Mining Version Histories to Guide Software Changes" (ROSE):
  association rules over co-changes; suggests the files that are likely missing from a change.
- Gall et al. 1998, logical coupling. Tornhill (CodeScene), "temporal coupling" and hotspots.

## What makes or breaks it
- **Support and confidence:** a minimum number of shared changes and a minimum share of one
  file's changes that also touch the other (8 of 10 = 0.8), or every pair that changed together
  twice looks coupled.
- **Noise:** skip commits that touch many files (about 30 or more: formatting, renames,
  dependency bumps), merge commits, bots, generated files and lockfiles; apply `.mailmap` and
  `.git-blame-ignore-revs` as in the authorship brief.
- **The unit of change:** on a squash-merged repo a commit on main is a whole pull request,
  the right unit. Agent branches commit in small steps, so mine only the main branch's history,
  never the branch under review.
- **Renames:** `--name-status -M` per commit, so a renamed file keeps its history.
- **Window:** 12–18 months, optionally weighted toward recent changes.

## Cost
One `git log --first-parent --name-status -M -z` over the window of the default branch,
parsed into pair counts. Cache it per repo, keyed by the default branch's tip, and refresh only
when that moves. Off the main actor; within the §8.7 budgets.

## Open questions
- Where the heads up shows: the file list's header, under the file's header, or the outline.
- Whether grouping becomes a file list mode beside the tree and the flat list.
- File level only, or definitions too (tree-sitter ranges) for large files.
