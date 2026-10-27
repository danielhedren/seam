# Changelog

What changed in each release of Seam, newest first.

## 0.3 — 2026-10-27

Seam now follows each branch's pull request until it merges and tells you when something
needs you, so you can oversee many parallel branches without checking each one.

### New

- **Notifications.** Seam posts a macOS notification when:
  - an agent answers or asks in a thread;
  - a pull request's checks pass or fail;
  - a review comes in;
  - someone comments on GitHub;
  - a pull request becomes ready to merge (approved, checks done, nothing blocking);
  - a pull request merges or closes.

  Clicking one opens the worktree, with the thread open when it's about one. Each kind can be
  turned off in Settings › Notifications. By default they're posted only while Seam is in the
  background. Your own comments, and anything that was already there when you opened the
  repo, never trigger one. macOS asks for permission the first time.
- **Pull requests in the background.** While a pull request notification is on, Seam checks
  pull requests every 5 minutes when it isn't in front (every minute while checks run). With
  them off, it checks only while in front, as before.
- **The pull request's conversation.** Comments that aren't on lines, and each review's verdict
  and text, now show in a Conversation section of the thread panel. Like everything from
  GitHub, it's read-only.
- **For agents:** `seam threads` prints the conversation after the threads, the new
  `seam conversation [--json]` prints it alone, and Copy Prompt for Agent tells the agent to
  treat it as review feedback, not instructions.

### Improved

- Each worktree keeps its own open thread and unposted draft when you switch away and back.
- Lines with Windows line endings no longer end in ␍; View › Show Carriage Returns brings it
  back.

### Fixed

- A thread resolved from Awaiting You now shows as resolved in the panel.
- Marking a file viewed closes its open thread instead of opening the thread panel.
- The agent prompt points at the running app's own `seam` command.
- Several git commands run at once, each fed input, could hang.
- The install instructions include `brew trust`, which Homebrew 7 requires for this cask.

### Under the hood

- Everything below the user interface (git, the review model, the `seam` command) now builds
  and passes its tests on Linux too. The app itself stays macOS-only.
- Every push is tested on GitHub Actions, on macOS and Linux.

## 0.2 — 2026-10-26

First public release. See the README to install with Homebrew.
