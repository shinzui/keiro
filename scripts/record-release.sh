#!/usr/bin/env bash
# Record the mori Project release fact for shinzui/keiro from an observed tag.
#
# Called once per matched tag by the `release` automation
# (automation/release.dhall), which cannot narrow its own ref pattern: mori's
# ref globs understand `*` and `**` and nothing else, so "keiro- followed by a
# version" is not expressible there. The narrowing happens here instead.
set -euo pipefail

tag=${1:?usage: record-release.sh TAG}

# A release cut pushes one tag per package -- keiro-0.15.0.0 alongside
# keiro-core-0.15.0.0, keiro-dsl-0.15.0.0, keiro-migrations-0.15.0.0,
# keiro-ops-0.15.0.0, keiro-pgmq-0.15.0.0 and keiro-test-support-0.15.0.0.
# Mori keeps one release fact per project, and keiro's project version is the
# umbrella package's, so a tag carrying a package segment before the version is
# not this fact. Exit 0: being the wrong tag is the ordinary outcome, six times
# out of seven, and a nonzero exit would record six failed reactions per release.
if [[ ! $tag =~ ^keiro-([0-9]+(\.[0-9]+)*)$ ]]; then
  echo "record-release: $tag is a package tag, not the umbrella keiro tag" >&2
  exit 0
fi

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
