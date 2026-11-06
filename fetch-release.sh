#!/bin/bash
# Fetch the release RELEASE names (https://huggingface.co/<org>/<repo>@<commit>) into MODEL, whole: every file at its
# full size. ds41 reads the release in place, and its loader needs every Engram part file (gr8/docs/DEEPSEEK-BOOT.md),
# so there is no per-box subset. A stopped fetch resumes where it left off. HF_TOKEN is sent to Hugging Face when set.
#
#   fetch-release.sh            fetch what is missing (FETCH_JOBS files at once, 8 by default), then check
#   fetch-release.sh --check    exit 0 when MODEL holds the whole release at RELEASE's commit, else 1
set -euo pipefail
url=${RELEASE:?RELEASE is not set}
dest=${MODEL:?MODEL is not set}
spec=${url#https://huggingface.co/}
repo=${spec%@*}
rev=${spec#*@}
[ "$rev" != "$spec" ] || rev=main
state=$(dirname "$dest")/.fetch-$(basename "$dest")   # the file list and the commit, beside the release
list=$state/files.tsv                                 # size TAB path, one line a file
auth=()
[ -z "${HF_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $HF_TOKEN")

whole() {
  [ -s "$list" ] && [ "$(cat "$state/rev" 2>/dev/null)" = "$rev" ] || return 1
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
if [ "$(cat "$state/rev" 2>/dev/null)" != "$rev" ] || [ ! -s "$list" ]; then
  curl -fsSL ${auth[@]+"${auth[@]}"} "https://huggingface.co/api/models/$repo/revision/$rev?blobs=true" \
    | jq -r '.siblings[] | "\(.size)\t\(.rfilename)"' > "$list.new"
  [ -s "$list.new" ] || { echo "fetch-release.sh: no file list for $repo@$rev" >&2; exit 1; }
  mv "$list.new" "$list"
  echo "$rev" > "$state/rev"
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
