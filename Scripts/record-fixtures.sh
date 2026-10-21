#!/bin/sh
# Regenerates Tests/GitKitTests/Fixtures from real git output (SPEC §10).
set -eu
out="$(cd "$(dirname "$0")/.." && pwd)/Tests/GitKitTests/Fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'

cd "$work"
git init -q -b main
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > modified.txt
printf 'keep\n' > deleted.txt
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n' > old-name.txt
printf 'same content\nfor a pure rename\n' > pure-old.txt
printf 'line\n' > mode.sh
printf 'no newline' > no-newline.txt
printf 'with space\n' > 'with space.txt'
printf 'unicode\n' > 'åäö.txt'
printf 'quoted\n' > 'quote"d.txt'
printf 'a\r\nb\r\n' > crlf.txt
printf '\000\001\002' > binary.bin
git add -A && git commit -q -m base

printf 'one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\neleven\n' > modified.txt
rm deleted.txt
git mv old-name.txt new-name.txt && printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\nTHETA\n' > new-name.txt
git mv pure-old.txt pure-new.txt
chmod +x mode.sh
printf 'no newline, changed' > no-newline.txt
printf 'with space, changed\n' > 'with space.txt'
printf 'unicode, changed\n' > 'åäö.txt'
printf 'quoted, changed\n' > 'quote"d.txt'
printf 'a\r\nB\r\n' > crlf.txt
printf '\000\001\003' > binary.bin
: > empty-added.txt
printf 'added\nfile\n' > added.txt
ln -s modified.txt link
git show HEAD:modified.txt > copy-of-modified.txt
git add -A

flags='diff --cached --no-ext-diff --no-color --no-textconv --histogram -M -C --src-prefix=a/ --dst-prefix=b/ -U3'
git -c core.quotepath=off $flags > "$out/worktree-changes.patch"
echo "wrote $out/worktree-changes.patch"

# Status on top of the staged changes: unstaged edits, untracked and ignored files.
printf 'one\nTWO\nthree, unstaged\n' > modified.txt
printf 'untracked\n' > 'untracked file.txt'
printf 'ignored.log\n' > .gitignore
printf 'log\n' > ignored.log
git -c core.quotepath=off status --porcelain=v2 -z --branch --ignored --untracked-files=all \
    > "$out/status.v2z"

# An unmerged path needs a conflict, so it comes from its own repository.
mkdir "$work/conflict" && cd "$work/conflict"
git init -q -b main
printf 'base\n' > both.txt && git add -A && git commit -q -m base
git checkout -q -b other && printf 'other\n' > both.txt && git commit -q -am other
git checkout -q main && printf 'main\n' > both.txt && git commit -q -am main
git merge -q other > /dev/null 2>&1 || true
git -c core.quotepath=off status --porcelain=v2 -z > "$out/status-unmerged.v2z"
echo "wrote $out/status.v2z and status-unmerged.v2z"
