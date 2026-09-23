#!/usr/bin/env bash
# Print the next release tag for the commits in <last-tag>..<sha>, or nothing
# when none of them is releasable. Squash merges make each PR title one subject.
#
#   `type!:` subject or `BREAKING CHANGE:` footer -> major
#   feat -> minor;  fix, perf -> patch;  any other type -> no release
#   `Release-As: X.Y.Z` footer -> exactly that version (must exceed <last-tag>)
set -euo pipefail

last=${1:?usage: next-version.sh <last-tag> <sha>}
sha=${2:?usage: next-version.sh <last-tag> <sha>}

subjects=$(git log --format=%s "${last}..${sha}")
bodies=$(git log --format=%b "${last}..${sha}")
[ -n "$subjects" ] || exit 0

scope='(\([^)]*\))?'
if grep -qE "^[a-z]+${scope}!: " <<<"$subjects" || grep -qE '^BREAKING[ -]CHANGE: ' <<<"$bodies"; then
  bump=major
elif grep -qE "^feat${scope}: " <<<"$subjects"; then
  bump=minor
elif grep -qE "^(fix|perf)${scope}: " <<<"$subjects"; then
  bump=patch
else
  bump=none
fi

IFS=. read -r major minor patch <<<"${last#v}"
case $bump in
  major) next="$((major + 1)).0.0" ;;
  minor) next="${major}.$((minor + 1)).0" ;;
  patch) next="${major}.${minor}.$((patch + 1))" ;;
  none) next="" ;;
esac

# PR bodies edited on github.com can carry CRLF, hence the trailing [[:space:]].
release_as=$({ grep -E '^Release-As: v?[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' <<<"$bodies" || true; } \
  | sed -E 's/^Release-As: v?//; s/[[:space:]]+$//' | sort -V | tail -1)
if [ -n "$release_as" ]; then
  highest=$(printf '%s\n%s\n' "${last#v}" "$release_as" | sort -V | tail -1)
  if [ "$release_as" = "${last#v}" ] || [ "$highest" != "$release_as" ]; then
    echo "Release-As: $release_as does not exceed $last" >&2
    exit 1
  fi
  next=$release_as
fi

if [ -n "$next" ]; then
  echo "v${next}"
fi
