#!/usr/bin/env bash
# Record the mori Project release fact for shinzui/keiro from an observed tag.
#
# Called once per release by the `release` automation (automation/release.dhall).
# That config's `refRegexes` already restricts the trigger to the umbrella
# `keiro-<version>` tag, so this script no longer filters: it exists only to do
# the two things a reaction cannot express -- strip the `keiro-` prefix and read
# the tag's own creation time.
set -euo pipefail

tag=${1:?usage: record-release.sh TAG}

# The selector guarantees this shape, so a mismatch is a bug in the selector or
# a hand-run with the wrong argument -- not the ordinary case it used to be.
# Fail loudly rather than recording a version that breaks the convention below.
if [[ ! $tag =~ ^keiro-([0-9]+(\.[0-9]+)*)$ ]]; then
  echo "record-release: $tag is not an umbrella keiro release tag" >&2
  exit 1
fi

# Mori keeps one release fact per project and keiro's project version is the
# umbrella package's, recorded without the tag prefix -- `0.16.0.0`, not
# `keiro-0.16.0.0` -- matching the 0.1.0.0-0.15.0.0 backfill. Versions are
# opaque to mori, so nothing but this line enforces that.
version=${BASH_REMATCH[1]}

# The tag's own creation time, not the observation time. The two agree when the
# daemon is healthy, but ingest can lag a tag by months, and the fact is
# immutable, so a wrong first write cannot be corrected later. This is the same
# UTC conversion the 0.1.0.0-0.15.0.0 backfill used, so an automated fact and a
# hand-recorded one describe a tag identically. Fall back to mori's default
# (now) only when git has nothing to offer.
released_at=$(TZ=UTC git for-each-ref \
  --format='%(creatordate:format-local:%Y-%m-%dT%H:%M:%SZ)' \
  "refs/tags/${tag}")

if [[ -n $released_at ]]; then
  exec mori registry release record shinzui/keiro "$version" \
    --released-at "$released_at" \
    --source "git-tag:${tag}"
fi

exec mori registry release record shinzui/keiro "$version" \
  --source "git-tag:${tag}"
