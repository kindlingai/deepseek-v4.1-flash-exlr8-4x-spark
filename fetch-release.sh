#!/bin/bash
# Fetch the release RELEASE names (https://huggingface.co/<org>/<repo>@<commit>) into MODEL, whole: every file at its
# full size and with the content the release lists for it. ds41 reads the release in place, and its loader needs every
# Engram part file (gr8/docs/DEEPSEEK-BOOT.md), so there is no per-box subset. A stopped fetch resumes where it left
# off. HF_TOKEN is sent to Hugging Face when set.
#
# Beside MODEL the script records the release and, for each file, its size, its Hugging Face blob id, and the hash of
# its content: the sha256 Hugging Face lists for a large (LFS) file, the git blob id (the sha1 of "blob <size>\0" and
# the content) for a small one. The fetch hashes each file once it has it and fetches it again, from the start, when
# the hash is wrong: a copy of the right size can still be wrong, a sparse copy with holes for one. Each file whose hash
# is right is recorded with its size, change time and inode, so later checks hash only the files that changed since.
# A file that changes while it is hashed is hashed again, 3 times at most; after that it counts as wrong.
#
# When RELEASE changes, the fetch deletes every file whose blob id differs from the new release's, or that the new
# release does not have, and fetches it again; files with the same content stay. A MODEL that holds files but has no
# record is refused: the script cannot tell which release they came from.
#
#   fetch-release.sh            fetch what is missing or wrong (FETCH_JOBS files at once, 8 by default), then check
#   fetch-release.sh --check    exit 0 when MODEL holds the whole release RELEASE names, else 1 (no network): every
#                               file at its size, then at its hash (FETCH_JOBS files at once). OK or MISMATCH for each
#                               file it hashes
set -euo pipefail
url=${RELEASE:?RELEASE is not set}
dest=${MODEL:?MODEL is not set}
spec=${url#https://huggingface.co/}
repo=${spec%@*}
rev=${spec#*@}
[ "$rev" != "$spec" ] || rev=main
state=$(dirname "$dest")/.fetch-$(basename "$dest")   # the record, beside the release
list=$state/sums.tsv                                  # size TAB hash TAB path, one line a file; hash is sha256:<hex>
                                                      # or blob:<git blob id>
blobs=$state/blobs.tsv                                # blob id TAB path: the content each file in MODEL is for
hashed=$state/hashed.tsv                              # "size ctime inode" TAB hash TAB path: files whose hash was right
auth=()
[ -z "${HF_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $HF_TOKEN")

verify() {  # $1 = "size TAB hash TAB path": 0 when the file has that size and that hash
  local size sum path sig got try
  IFS=$'\t' read -r size sum path <<< "$1"
  for try in 1 2 3; do
    sig=$(stat -c '%s %.9Z %i' "$dest/$path" 2>/dev/null) || { echo "$path: missing" >&2; return 1; }
    [ "${sig%% *}" = "$size" ] || { echo "$path: ${sig%% *} bytes, want $size" >&2; return 1; }
    grep -qFx -- "$sig"$'\t'"$sum"$'\t'"$path" "$hashed" 2>/dev/null && return 0   # hashed before, unchanged since
    case $sum in
      sha256:*) got=sha256:$(sha256sum < "$dest/$path" | cut -c1-64) ;;
      blob:*) got=blob:$({ printf 'blob %s\0' "$size"; cat "$dest/$path"; } | sha1sum | cut -c1-40) ;;
      *) got=none ;;
    esac
    # A file that changed while it was hashed no longer holds the bytes that were hashed: hash it again
    [ "$(stat -c '%s %.9Z %i' "$dest/$path" 2>/dev/null)" != "$sig" ] || break
    [ "$try" != 3 ] || { echo "$path: changed while it was hashed, 3 times" >&2; return 1; }
  done
  [ "$got" = "$sum" ] || { echo "MISMATCH $path: ${got#*:}, want ${sum#*:} (${sum%%:*})" >&2; return 1; }
  echo "OK $path"
  { printf '%s\t%s\t%s\n' "$sig" "$sum" "$path" >> "$hashed"; } 2> /dev/null || true
}

whole() {
  if [ ! -s "$list" ] || [ "$(cat "$state/release" 2>/dev/null)" != "$repo@$rev" ]; then
    echo "fetch-release.sh: no record that $dest holds $repo@$rev, with each file's hash (run the fetch)" >&2
    return 1
  fi
  local size sum path
  while IFS=$'\t' read -r size sum path; do   # the sizes first: quick
    [ "$(stat -c %s "$dest/$path" 2>/dev/null)" = "$size" ] ||
      { echo "fetch-release.sh: $path is missing or not at its size" >&2; return 1; }
  done < "$list"
  touch "$hashed" 2> /dev/null ||
    echo "fetch-release.sh: cannot write $hashed: every check hashes every file again" >&2
  tr '\n' '\0' < "$list" | xargs -0 -n 1 -P "${FETCH_JOBS:-8}" "$0" --verify || return 1   # then the hashes
}

get() {  # $1 = path, $2 = size: fetch the rest of the file
  curl -fsSL --retry 10 --retry-all-errors --retry-delay 5 ${auth[@]+"${auth[@]}"} -C - -o "$dest/$1" \
    "https://huggingface.co/$repo/resolve/$rev/$1"
  local have
  have=$(stat -c %s "$dest/$1")
  [ "$have" = "$2" ] || { echo "$1: $have bytes, want $2" >&2; return 1; }
  echo "fetched $1"
}

one() {  # $1 = "size TAB hash TAB path": fetch one file unless it is already whole
  local size sum path have
  IFS=$'\t' read -r size sum path <<< "$1"
  mkdir -p "$(dirname "$dest/$path")"
  [ "$size" != 0 ] || { : > "$dest/$path"; return 0; }
  have=$(stat -c %s "$dest/$path" 2>/dev/null || echo 0)
  if [ "$have" = "$size" ]; then
    verify "$1" && return 0
    rm -f -- "$dest/$path"                            # the right size but not the right content: start it again
  elif [ "$have" -gt "$size" ]; then
    rm -f -- "$dest/$path"                            # longer than the release's file: start it again
  fi
  get "$path" "$size" || return 1                     # a stopped download keeps its part: the next fetch resumes it
  verify "$1" && return 0
  rm -f -- "$dest/$path"                              # a resumed file can carry a wrong first part: once more, whole
  get "$path" "$size" && verify "$1"
}

case "${1:-}" in
  --check) whole; exit ;;
  --one) one "$2"; exit ;;
  --verify) verify "$2"; exit ;;
  '') ;;
  *) echo "fetch-release.sh: want no argument, or --check" >&2; exit 2 ;;
esac

mkdir -p "$state" "$dest"
# The file list again when RELEASE changed, when the record has no hashes (a fetch from before the script hashed), or
# always when RELEASE names a branch rather than a commit (a branch moves)
if [ "$(cat "$state/release" 2>/dev/null)" != "$repo@$rev" ] || [ ! -s "$list" ] || [ ! -s "$blobs" ] ||
   ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
  curl -fsSL ${auth[@]+"${auth[@]}"} "https://huggingface.co/api/models/$repo/revision/$rev?blobs=true" > "$state/api.json"
  jq -e '.siblings | length > 0 and
      all(.[]; .size != null and .blobId != null and (.lfs == null or .lfs.sha256 != null))' "$state/api.json" \
    > /dev/null ||
    { echo "fetch-release.sh: no file list with sizes, blob ids and hashes for $repo@$rev" >&2; exit 1; }
  jq -r '.siblings[] | "\(.size)\t\(if .lfs then "sha256:\(.lfs.sha256)" else "blob:\(.blobId)" end)\t\(.rfilename)"' \
    "$state/api.json" > "$list.new"
  jq -r '.siblings[] | "\(.blobId)\t\(.rfilename)"' "$state/api.json" > "$blobs.new"
  rm -f "$state/api.json"
  ! cut -f3 "$list.new" | grep -qE '^/|(^|/)\.\.(/|$)' ||
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
  rm -f "$state/files.tsv"                            # the list from before the script hashed
  echo "$repo@$rev" > "$state/release"
fi
files=$(wc -l < "$list")
want=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$list")
have=$(du -s --block-size=1 "$dest" | cut -f1)        # the space in use: a sparse file counts what it holds
free=$(df --output=avail --block-size=1 "$dest" | tail -1)
echo "fetch-release.sh: $repo@$rev, $files files, $((want / 1000000000)) GB; $((have / 1000000000)) GB here, $((free / 1000000000)) GB free"
[ $((want - have)) -lt "$free" ] || { echo "fetch-release.sh: not enough free space in $dest" >&2; exit 1; }
start=$(date +%s)
export RELEASE MODEL HF_TOKEN
tr '\n' '\0' < "$list" | xargs -0 -n 1 -P "${FETCH_JOBS:-8}" "$0" --one || true   # a failed file: the check below says so
whole || { echo "fetch-release.sh: the release is still not whole: run the fetch again" >&2; exit 1; }
echo "fetch-release.sh: the release is whole in $dest, and every file's hash is right ($(( $(date +%s) - start )) s)"
