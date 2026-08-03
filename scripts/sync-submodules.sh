#!/usr/bin/env bash
# Advance every submodule to the HEAD of its tracked branch and print the
# resolved SHAs.
#
# WHY: a submodule pins an exact commit, and unless something actively advances
# it, the parent silently keeps building a STALE checkout — this has bitten us
# (e.g. a baked `hm` 26 commits behind harmont-cli@main, missing the bun
# toolchain). Each submodule declares `branch = <b>` in .gitmodules; with that,
# `git submodule update --remote` follows that branch's upstream HEAD on every
# run instead of the frozen pin. Run this in the deploy bake (so the runner's hm
# matches harmont-cli@main) and in the dev bootstrap (so local hm matches too).
#
# The committed pin stays as a fallback for plain `git submodule update` / fresh
# clones; this script is what makes "track HEAD" happen at build/dev time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Syncing submodules to tracked-branch HEAD (git submodule update --remote)"
git submodule sync --recursive
git submodule update --init --remote --recursive
echo "    resolved:"
git submodule status --recursive | sed 's/^/      /'
