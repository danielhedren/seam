# 1. Run the git CLI, not libgit2

Status: accepted (2026-10-21)

## Context

Seam must show the same diff the user would get in the terminal: their `.gitattributes`,
`includeIf` config, worktrees, rename detection and diff algorithms. Worktrees are created by
agents with whatever git the user has installed.

## Decision

Every git operation goes through `GitClient`, implemented by `CLIGitClient`, which runs the user's
own `git`. Each call passes every option whose user config would change the output
(`--src-prefix/--dst-prefix`, `--no-color`, `--no-ext-diff`, `--no-textconv`, `--histogram`, `-M -C`,
`-U<n>`, `core.quotepath=off`), sets `GIT_OPTIONAL_LOCKS=0` so reads never take the index lock,
and parses porcelain / `-z` formats where they exist.

## Consequences

- Behaviour matches the terminal, including new git features, at the cost of a process per call
  (~5–10 ms each). Detection (SPEC §5.1) is designed around few calls for that reason.
- Parsing patch text is our responsibility; the round-trip property test guards it.
- libgit2 was rejected: its worktree, attribute and diff behaviour drifts from git's, and it adds
  a C dependency.
