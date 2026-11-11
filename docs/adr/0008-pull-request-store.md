# 8. Fetch pull requests into a store of Seam's own

Status: accepted (2026-11-11)

## Context

Seam is to review the repo's open pull requests that have no worktree here (SPEC §7.2.2, §6.4).
Their commits are often not in the repo, and SPEC §5.5 forbids Seam to fetch into it. Measured
on a repo with 97 open PRs (median 5 files, largest 240 files and 28k lines):

| | `gh pr diff` per PR | Seam's own store |
|---|---|---|
| Getting them | 1.2–2.3 s and one REST call each | one fetch of all heads and bases: 2.2 s cold, ~1 s when nothing changed |
| Largest PR | refused: "diff exceeded the maximum number of lines (20000)" | diffed |
| Full files, context, highlighting, commits | no | yes, through the worktree pipeline |
| Diffing locally | | 97 PRs in 3.5 s |

80 of the 97 heads were already in the repo from the user's own fetch, and the store holding the
rest was 1.5 MB. Against the repo's `origin/main` (8 hours old) 9 PRs showed the wrong files;
with the base branches fetched too, all 97 matched GitHub's file counts.

## Decision

`PullRequestStore` keeps a bare repository under Application Support whose
`objects/info/alternates` names the repo's object directory, and fetches every listed PR's
`refs/pull/N/head` and base branch into it in one `git fetch --no-tags --no-write-fetch-head`.
The fetch goes over https to the PR remote's host with gh's credential helper, and with the
user's global and system git config cleared. Reviews read the store with `--git-dir` through the
ordinary `GitClient`. The repo is only read.

## Consequences

- PR reviews get the worktree pipeline unchanged: histogram diff, full files, highlighting,
  definitions, commits, blob-keyed viewed marks.
- Seam now writes outside the repo to a git directory and reaches GitHub through git as well as
  `gh`. It still writes nothing to the repo or to GitHub.
- ssh was rejected: a repo's own `core.sshCommand`, picking the key for that host, lives in the
  repo's config, and the fetch from the store failed with "Repository not found". Clearing the
  global config also drops an `http.proxy` set there; a user who needs one has no workaround yet.
- A `git gc` in the repo can drop objects the store borrows; the store is a cache, deleted and
  refetched when a read finds an object missing.
- `GIT_OBJECT_DIRECTORY` tricks run in the repo were rejected: one missed flag writes refs or
  `FETCH_HEAD` into `.git`.
- Fetching each file's two sides from the API was rejected: about 200 calls for a 100-file PR.
