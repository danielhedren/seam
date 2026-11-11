# Brief: Authorship signals for a diff review tool

Received 2026-11-11, not yet designed or scheduled. The brief as given, then notes on how it
meets Seam's constraints.

## Goal
For a diff (e.g. `main...HEAD`), show (1) who owns each touched file, measured with
Degree of Authorship (DOA), and (2) who wrote the specific code regions the diff changes
("region authors"). The output is for triage and reviewer routing. It is NOT a gate and
NOT a score for individual developers.

## Why ownership matters
- Bird et al. (2011, Microsoft, "Don't Touch My Code!"): components with many minor
  contributors (<5% of commits) had significantly more defects. Ownership was one of the
  strongest predictors in that study.
- Bird measured at component level (binaries/directories). File-level replications are
  mixed: Greiler et al. 2015 still found an effect at Microsoft, while OSS studies found
  a weaker one. Treat ownership as a risk signal, not proof.
- Practical value: a change by someone with no history in the code is the classic
  high-risk pattern, and the cheapest fix is a review by whoever does have that history.

## Degree of Authorship (DOA)
Source: Fritz et al.; thresholds from Avelino et al. 2016 (truck factor).
Computed per (developer, file):

    DOA = 3.293 + 1.098·FA + 0.164·DL − 0.321·ln(1 + AC)

- FA = 1 if the developer created the file, else 0
- DL = number of commits by the developer to the file
- AC = number of commits to the file by other developers

Normalize per file: DOA_norm = DOA / max(DOA over all developers of that file).
A developer is an author of the file if DOA_norm > 0.75 AND DOA > 3.293.

Why DOA instead of commit share or blame:
- Commit share counts a typo fix the same as writing the module.
- Blame share is distorted by formatting, renames and moved code.
- DOA weights creation, grows with your own changes, and decays as others change the
  file. That matches how familiarity with code actually works.

## Region authors
Definition: for each hunk in the diff, the developers who wrote the lines being changed,
plus the developers who own the enclosing method.

Why show them in addition to file-level DOA:
1. Large files dilute ownership. A 3,000-line hotspot can have ten "authors" at file
   level while each method has one clear owner. File-level DOA then makes the file look
   diffusely owned when it isn't.
2. Exact reviewer routing. "Ask the person who wrote these lines" beats "ask someone who
   has touched this file."
3. Outsider detection at the right granularity. Flag hunks where the diff's author is
   not among that region's authors, even if they own the file in general.
4. Context for the reviewer. Recency tells them whether the region's author still has
   it in their head: written last month vs. untouched for three years.
5. Compare with CODEOWNERS. Surface mismatches where the declared owner never wrote the
   touched regions.

How to compute:
- Modified/deleted lines: `git blame -w -M -C --line-porcelain -L <start>,<end> <base_rev> -- <file>`
  run on the BASE revision's line ranges for each hunk.
- Added-only hunks: there's nothing to blame, so use the enclosing method.
- Method-level history: add `.gitattributes` entries (`*.cs diff=csharp`,
  `*.rs diff=rust`), then run `git log -L :<funcname>:<file> -s --format='%ae'`.
  Run on demand only for methods the diff touches. It's slow, and it breaks on
  renames and moves.
- Aggregate per hunk: author → number of lines and last-touched date.

## Data hygiene (required)
- Apply `.mailmap` so one person with several emails counts as one developer.
- Exclude bots, merge commits, generated files, lockfiles and migrations.
- Use `.git-blame-ignore-revs` for formatting and mass-rename commits.
- Use a time window for history (12–18 months), optionally weighted toward recent changes.
- Rename tracking: `--follow` only works for one file at a time, so handle renames
  explicitly or accept the gaps.
- Squash merges collapse authorship. Note this as a known limitation.

## Output per touched file
- File-level DOA authors (name, DOA_norm), and whether the diff author is one of them
- Per hunk: region authors with line counts and recency, plus a flag if the diff author
  isn't among them
- Suggested reviewer(s): top region author, falling back to the top file author, then
  the directory owner
- CODEOWNERS mismatch, if any

## Guardrails
- Present this as risk and routing information, never as a judgment of people.
  Once it reads like a scorecard, people game it (squashing commits, avoiding
  unfamiliar code) and the signal is lost.
- Rank by percentiles within the repo. Don't use absolute thresholds.

---

## Notes for Seam (first thoughts, to check before designing)

- **No `.gitattributes` edits:** Seam never writes to the repo (AGENTS.md, SPEC §5.5), so it
  can't add `diff=csharp` lines. For method history, use the definition ranges Seam already
  parses with tree-sitter (SPEC §8.4) as `git log -L <start>,<end>:<file>` on the base, or
  pass the funcname pattern with `-c diff.<driver>.xfuncname=…`.
- **Agent authors:** in a worktree, the diff's author is usually an agent committing as the
  reader, so "the diff author isn't among the region's authors" may say little there. It
  likely matters most on pull request reviews (M11), where the author is another person.
- **Cost:** blame per hunk and `log` per touched file have to fit the §8.7 budgets. They would
  run off the main actor after first paint, like highlighting, and be cached by blob id.
- **Guardrails:** the brief's guardrail fits Seam's stance of facts, not scores (the "worth a
  look" list and per-file risk scores were dropped for that reason, SPEC §16).
