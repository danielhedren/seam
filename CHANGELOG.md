# Changelog

What changed in each release of Seam, newest first.

## 0.4 — 2026-10-27

Threads move out of the side panel and into the diff, where the code is: the diff keeps the
window's width, and every thread, outdated ones included, has a card in it.

### New

- **Threads.** The Inbox becomes Threads, in the file list's column (the toolbar's Threads
  button, or ⇧⌘I): what awaits you across every worktree first, then the selected worktree's
  pull request conversation and its threads by file, with Copy Prompt for Agent in its header.
  Picking one opens its card in the diff and scrolls to it.
- **Every thread has a card in the diff.** A thread on lines hidden between hunks shows where
  they'd be; a comment on a whole file shows under its header; a thread on a file the diff
  doesn't show, and the pull request's conversation, show above the first file.
- **What became of an outdated thread.** Its card goes after whatever replaced its lines, and
  opened, it shows "Changed since this comment": the diff from the code it was written on to
  the code now, a few lines around them.
- **Jump to Commit** (⇧T, or the button on an outdated thread's card) now works for Seam's
  own threads too, and lands on the thread, open on its lines, in the diff it was written on.
- **Threads down the right edge.** A tick over the scroller marks where each thread is, so
  they're seen before they're scrolled to.
- **Closed threads look like cards.** A thread that isn't open shows as its card collapsed: its
  title (with GitHub's mark on GitHub's) and its latest comment. Clicking the title opens it.

### Improved

- Opening a thread whose card doesn't fit scrolls it in from its top, with its code above it,
  rather than leaving it at the bottom edge.
- Notifications show a comment as plain text, without its Markdown or HTML comments.
- A line total of 0 is grey, and "untracked" and "generated" follow a file's path in grey.
- A finished review lists the pull request's facts one to a line, and Open Failed Check looks
  like a link.
- The commit list's Show All is now Select All.
- Pull requests are read with fewer `gh` calls: reviews and checks only when the pull request
  changed, and one write of the GitHub file per refresh.

### Fixed

- Switching between Files and Threads no longer changes the column's width.
- A pull request read that finished after pull requests were turned off no longer brings their
  threads back.
- Settings › Notifications names the switch pull request notifications need.

### Removed

- The thread panel on the right, and ⌥⌘0 with it: Threads and the cards in the diff do its
  work.

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
