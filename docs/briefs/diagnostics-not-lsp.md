# Brief: compiler diagnostics in the review, not a language server

Looked into 2026-11-12 after Go to Symbol and Find Definition and Uses were dropped from M12.
Verdict: no language server integration; a narrow spike on importing diagnostics instead.

## What a language server would give a reviewer
Of what LSP offers, two things are review facts rather than editor features:

- **Diagnostics on changed lines** (`publishDiagnostics`, `textDocument/diagnostic`): the same as
  the compiler's output from a build, which agents already run.
- **References to a changed definition** (`textDocument/references`): "14 callers, none in this
  diff", for a behaviour change behind an unchanged signature. The one thing a build can't say.

Hover types, call hierarchy, semantic tokens and rename are editor features or not worth it
(tree-sitter already colours the diff; M13's labels cover renames from the diff itself).

## Why not
- **Pull requests:** the PR store has no working tree. A server needs a checkout with packages
  restored, which means network, minutes and gigabytes per PR.
- **Running a stranger's code:** indexing runs it. rust-analyzer runs `build.rs` and proc
  macros, Roslyn evaluates MSBuild, and tsserver loads plugins from `tsconfig`.
- **Writes into the worktree:** `target/`, `obj/` and `.build/` are written and locked,
  contending with the agent's own build and adding to FSEvents churn.
- **Cost:** one server per language per worktree, tens of seconds to minutes cold and 1–4 GB
  each (from memory, not measured). Only on demand for the selected worktree would work, far
  past the 200 ms first paint, against "idle CPU ~0".
- **Dependencies:** bundling is a new dependency per language; discovery is fragile. On this
  Mac Roslyn exists only inside the VS Code C# extension, and no TypeScript or PHP server is
  installed.

## Instead: a spike (about 3–5 days)
1. A pure SARIF 2.1.0 parser in SeamCore. C# writes SARIF natively
   (`dotnet build -p:ErrorLog=out.sarif`); Rust, TypeScript and PHPStan have JSON output that
   could follow.
2. `seam diagnostics import <file>`: the agent runs its build and hands Seam the result, stored
   in Seam's state per worktree and head SHA, like threads. Seam runs nothing and writes nothing
   in the repo; a different SHA shows the results as stale.
3. A gutter mark and its message on changed lines, a per-file count, and errors anywhere.

For other people's PRs, CI already ran: GitHub check-run annotations
(`gh api repos/{o}/{r}/check-runs/{id}/annotations`) carry file, line and message, and could
feed the same model through the read-only `gh` (ADR 0005). Unverified how many of the user's
repos emit them.

Fits the agent skills brief: the skill tells the agent to run the import.

## Would change the verdict
The spike shows diagnostics get used, `git grep` caller counts mislead often enough, and a
measurement of Roslyn on a real solution shows cold start under about 30 s, under about 2 GB,
and no writes beyond `obj/`. Even then: `textDocument/references` only, one language, local
worktrees only.
