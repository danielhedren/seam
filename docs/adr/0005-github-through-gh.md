# 5. Read pull requests through the gh CLI, read-only

Status: accepted (2026-10-23)

## Context

The worktree list should show each branch's pull request and its state (SPEC §14, M6). The user
already has `gh` signed in to their hosts; Seam has no account of its own and must never change
the repository, nor anything on GitHub.

## Decision

`GitHubClient` in GitKit, implemented by `CLIGitHubClient`, runs the user's `gh` like
`CLIGitClient` runs git. It has typed read methods only, no generic runner, because `gh api -f`
silently turns a read into a POST. Each call passes `-R HOST/OWNER/REPO`, runs with the working
directory outside every repository and `GH_PROMPT_DISABLED=1`, and strips `GH_REPO`/`GH_HOST`,
so gh can't prompt, pick a remote itself or write `gh-resolved` into `.git/config`. Hosts are the
ones gh is signed in to (`gh auth status --json hosts --no-refresh`). gh's path comes from the
login shell, as the editor's does; when it's missing, the client says so without spawning.

## Consequences

- No token handling, OAuth or GitHub dependency in Seam; whatever gh supports (Enterprise, SSO,
  `GH_TOKEN`) works.
- Each refresh costs a process and a network round trip, so a repository's PRs come from one
  batched `gh pr list` and refreshes are coalesced and backed off.
- Seam can't post to GitHub. Writing would need a separate protocol and a new decision.
- Calling the GitHub API directly was rejected: it means storing a token and re-implementing
  gh's host and auth handling.
