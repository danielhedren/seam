# 6. Read review threads through gh api graphql with fixed queries

Status: accepted (2026-10-23)

## Context

M7 shows a pull request's review threads beside Seam's own (SPEC §7.9). `gh pr view --json`
gives a PR's conversation and its reviews' bodies, but not the comments on lines; those, with
their path, side, lines, diff hunk and resolved state, come only from GitHub's GraphQL API, which
gh reaches through `gh api graphql`. ADR 0005 kept `gh api` out because its `-f` flag turns a
read into a POST.

## Decision

`CLIGitHubClient` gets one more typed read method, `reviewThreads(_:in:)`, which runs
`gh api graphql --hostname HOST -f query=… -F number=… -f owner=… -f name=…` with queries fixed
in GitKit. GraphQL sends every query as a POST, but a query can't change anything; only a
`mutation` can, and none of the fixed queries contains one, which a test checks. There is still
no way to hand gh an arbitrary command. The other rules of ADR 0005 apply unchanged: `-R`'s
host passed as `--hostname`, prompts off, run outside any repository.

## Consequences

- A thread read costs one or two of GitHub's GraphQL points, so threads are read only when a
  PR's update time changes, which the cheap `gh pr list` already reports.
- Seam still can't post to GitHub. Agents answer GitHub's threads with their own `gh`, using the
  command `seam threads` prints; that is the agent's write, made with the user's say-so in the
  prompt, not Seam's.
- Calling the REST API's review comments endpoint was rejected: it has no resolved state and no
  thread grouping, so threads would have to be rebuilt from `in_reply_to_id`.
- M9: the first page's query also reads the PR's latest 100 conversation comments and reviews,
  and the viewer's login, so the conversation costs no second call. It is still a fixed query
  without a mutation.
