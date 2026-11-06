#!/bin/bash
# Fetch the release RELEASE names (https://huggingface.co/<org>/<repo>@<commit>) into MODEL, whole: every file at its
# full size. ds41 reads the release in place, and its loader needs every Engram part file (gr8/docs/DEEPSEEK-BOOT.md),
# so there is no per-box subset. A stopped fetch resumes where it left off. HF_TOKEN is sent to Hugging Face when set.
#
# Beside MODEL the script records the release and each file's Hugging Face blob id (a hash of the file's content).
# When RELEASE changes, the fetch deletes every file whose blob id differs from the new release's, or that the new
# release does not have, and fetches it again; files with the same content stay. A MODEL that holds files but has no
# record is refused: the script cannot tell which release they came from.
#
#   fetch-release.sh            fetch what is missing (FETCH_JOBS files at once, 8 by default), then check
#   fetch-release.sh --check    exit 0 when MODEL holds the whole release RELEASE names, else 1 (no network)
set -euo pipefail
url=${RELEASE:?RELEASE is not set}
dest=${MODEL:?MODEL is not set}
spec=${url#https://huggingface.co/}
repo=${spec%@*}
rev=${spec#*@}
[ "$rev" != "$spec" ] || rev=main
state=$(dirname "$dest")/.fetch-$(basename "$dest")   # the record, beside the release
list=$state/files.tsv                                 # size TAB path, one line a file
blobs=$state/blobs.tsv                                # blob id TAB path: the content each file in MODEL is for
auth=()
[ -z "${HF_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $HF_TOKEN")

whole() {
  [ -s "$list" ] && [ "$(cat "$state/release" 2>/dev/null)" = "$repo@$rev" ] || return 1
  local size path
  while IFS=$'\t' read -r size path; do
    [ "$(stat -c %s "$dest/$path" 2>/dev/null)" = "$size" ] || return 1
  done < "$list"
}

one() {  # $1 = "size TAB path": fetch one file unless it is already whole
  local size=${1%%$'\t'*} path=${1#*$'\t'} have
  mkdir -p "$(dirname "$dest/$path")"
  [ "$size" != 0 ] || { : > "$dest/$path"; return 0; }
  have=$(stat -c %s "$dest/$path" 2>/dev/null || echo 0)
  [ "$have" = "$size" ] && return 0
  [ "$have" -lt "$size" ] || rm -f "$dest/$path"      # longer than the release's file: start it again
  curl -fsSL --retry 10 --retry-all-errors --retry-delay 5 ${auth[@]+"${auth[@]}"} -C - -o "$dest/$path" \
    "https://huggingface.co/$repo/resolve/$rev/$path"
  have=$(stat -c %s "$dest/$path")
  [ "$have" = "$size" ] || { echo "$path: $have bytes, want $size" >&2; return 1; }
  echo "fetched $path"
}

case "${1:-}" in
  --check) whole; exit ;;
  --one) one "$2"; exit ;;
  '') ;;
  *) echo "fetch-release.sh: want no argument, or --check" >&2; exit 2 ;;
esac

mkdir -p "$state" "$dest"
# The file list again when RELEASE changed, or always when it names a branch rather than a commit (a branch moves)
if [ "$(cat "$state/release" 2>/dev/null)" != "$repo@$rev" ] || [ ! -s "$list" ] || [ ! -s "$blobs" ] ||
   ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
  curl -fsSL ${auth[@]+"${auth[@]}"} "https://huggingface.co/api/models/$repo/revision/$rev?blobs=true" > "$state/api.json"
  jq -e '.siblings | length > 0 and all(.[]; .size != null and .blobId != null)' "$state/api.json" > /dev/null ||
    { echo "fetch-release.sh: no file list with sizes and blob ids for $repo@$rev" >&2; exit 1; }
  jq -r '.siblings[] | "\(.size)\t\(.rfilename)"' "$state/api.json" > "$list.new"
  jq -r '.siblings[] | "\(.blobId)\t\(.rfilename)"' "$state/api.json" > "$blobs.new"
  rm -f "$state/api.json"
  ! cut -f2 "$list.new" | grep -qE '^/|(^|/)\.\.(/|$)' ||
    { echo "fetch-release.sh: a file of $repo@$rev has a path outside MODEL" >&2; exit 1; }
  if [ -s "$blobs" ]; then
    # Another release (or the branch moved): delete each file whose content the new release does not have at that path
    awk -F'\t' 'FILENAME == ARGV[1] { old[$2] = $1; next } { new[$2] = $1 }
      END { for (p in old) if (old[p] != new[p]) print p; for (p in new) if (!(p in old)) print p }' "$blobs" "$blobs.new" |
      while IFS= read -r path; do rm -f -- "$dest/$path"; done
  elif [ -n "$(ls -A "$dest")" ]; then
    echo "fetch-release.sh: $dest holds files but there is no record of their release ($blobs): empty it first" >&2
    exit 1
  fi
  mv "$list.new" "$list"
  mv "$blobs.new" "$blobs"
  echo "$repo@$rev" > "$state/release"
fi
files=$(wc -l < "$list")
want=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$list")
have=$(du -s --block-size=1 --apparent-size "$dest" | cut -f1)
free=$(df --output=avail --block-size=1 "$dest" | tail -1)
echo "fetch-release.sh: $repo@$rev, $files files, $((want / 1000000000)) GB; $((have / 1000000000)) GB here, $((free / 1000000000)) GB free"
[ $((want - have)) -lt "$free" ] || { echo "fetch-release.sh: not enough free space in $dest" >&2; exit 1; }
start=$(date +%s)
export RELEASE MODEL HF_TOKEN
tr '\n' '\0' < "$list" | xargs -0 -n 1 -P "${FETCH_JOBS:-8}" "$0" --one || true   # a failed file: the check below says so
whole || { echo "fetch-release.sh: the release is still not whole: run the fetch again" >&2; exit 1; }
echo "fetch-release.sh: the release is whole in $dest ($(( $(date +%s) - start )) s)"
