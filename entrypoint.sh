#!/bin/bash
# The recipe's own commands, then gr8's entrypoint (gr8/docker/entrypoint.sh) with the recipe's knobs (knobs.sh):
#   fetch   fetch the whole release into the release volume (fetch-release.sh); run it once on every box
#   up      (the default) migrate a fetch record from an image older than sha-fe21314 (fetch-release.sh --migrate),
#           refuse to start until the release is whole, put Engram's token map in place, then boot
set -euo pipefail
args=("$@")
while [ "${1:-}" = --no-check ]; do shift; done
cmd=${1:-up}
if [ "$cmd" = fetch ]; then
  shift
  exec /opt/ds41-4x/fetch-release.sh "$@"
fi
. /opt/ds41-4x/knobs.sh
if [ "$cmd" = up ]; then
  if ! /opt/ds41-4x/fetch-release.sh --migrate; then
    echo "ds41-4x: the fetch record beside $MODEL is from an older image and was not migrated (above)" >&2
    exit 2
  fi
  if ! /opt/ds41-4x/fetch-release.sh --check; then
    echo "ds41-4x: the release in $MODEL is not whole: run the fetch first, on every box (README.md, Quickstart)" >&2
    exit 2
  fi
  # The token map the image carries (Dockerfile, engram stage). The loader writes its index next to it at every boot,
  # so it lives in the home volume, not in the read-only image.
  mkdir -p "$(dirname "$ENGRAM_PREFIX")"
  cmp -s /opt/ds41-4x/ds41.engram.cmap "$ENGRAM_PREFIX.engram.cmap" \
    || cp /opt/ds41-4x/ds41.engram.cmap "$ENGRAM_PREFIX.engram.cmap"
fi
exec /opt/gr8/docker/entrypoint.sh ${args[@]+"${args[@]}"}
