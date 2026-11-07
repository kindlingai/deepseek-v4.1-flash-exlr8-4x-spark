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
# A file that changes while it is hashed is hashed again, once; when it changes again, it counts as wrong (MISMATCH).
#
# When RELEASE changes, the fetch deletes every file whose blob id differs from the new release's, or that the new
# release does not have, and fetches it again; files with the same content stay. A MODEL that holds files but has no
# record is refused: the script cannot tell which release they came from.
#
# A record from an image built before the script hashed (#5: blob ids and sizes, no hashes) is migrated, not fetched
# again: the script fetches only the file list, checks that every path has the record's blob id and size, then hashes
# every file once, check only, and writes the hashes into the record. It deletes and downloads nothing. A file that
# differs is named and the script stops; --force deletes such files and fetches them again.
#
#   fetch-release.sh            fetch what is missing or wrong (FETCH_JOBS files at once, 8 by default), then check;
#                               migrate an old record instead
#   fetch-release.sh --force    the same, and a file that differs from an old record is deleted and fetched again
#   fetch-release.sh --check    exit 0 when MODEL holds the whole release RELEASE names, else 1 (no network): every
#                               file at its size, then at its hash (FETCH_JOBS files at once). OK or MISMATCH for each
#                               file it hashes
#   fetch-release.sh --migrate  migrate an old record (exit 1 when a file differs); exit 0 at once when there is none
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
  for try in 1 2; do
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
    [ "$try" != 2 ] || { echo "MISMATCH $path: it changed while it was hashed, twice" >&2; return 1; }
  done
  [ "$got" = "$sum" ] || { echo "MISMATCH $path: ${got#*:}, want ${sum#*:} (${sum%%:*})" >&2; return 1; }
  echo "OK $path"
  { printf '%s\t%s\t%s\n' "$sig" "$sum" "$path" >> "$hashed"; } 2> /dev/null || true
}

whole() {  # $1 = the list to check against, the record's by default
  local l=${1:-$list} size sum path
  if [ ! -s "$l" ] || [ "$(cat "$state/release" 2>/dev/null)" != "$repo@$rev" ]; then
    echo "fetch-release.sh: no record that $dest holds $repo@$rev, with each file's hash (run the fetch)" >&2
    return 1
  fi
  while IFS=$'\t' read -r size sum path; do   # the sizes first: quick
    [ "$(stat -c %s "$dest/$path" 2>/dev/null)" = "$size" ] ||
      { echo "fetch-release.sh: $path is missing or not at its size" >&2; return 1; }
  done < "$l"
  touch "$hashed" 2> /dev/null ||
    echo "fetch-release.sh: cannot write $hashed: every check hashes every file again" >&2
  tr '\n' '\0' < "$l" | xargs -0 -n 1 -P "${FETCH_JOBS:-8}" "$0" --verify || return 1   # then the hashes
}

newlist() {  # the release's file list from Hugging Face, into $list.new and $blobs.new
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
}

old_record() {  # a record from before the script hashed, for this release: blob ids and sizes, no hashes
  [ "$(cat "$state/release" 2>/dev/null)" = "$repo@$rev" ] && [ ! -s "$list" ] && [ -s "$blobs" ] &&
    [ -s "$state/files.tsv" ]
}

migrate() {  # the old record to one with hashes, after a check-only hash pass: nothing deleted, nothing downloaded
  local differ files want secs start
  newlist
  differ=$(awk -F'\t' 'FILENAME == ARGV[1] { ob[$2] = $1; next } FILENAME == ARGV[2] { os[$2] = $1; next }
      FILENAME == ARGV[3] { nb[$2] = $1; next } { ns[$3] = $1 }
      END { for (p in ob) if (!(p in nb) || ob[p] != nb[p] || os[p] != ns[p]) print p
            for (p in nb) if (!(p in ob)) print p }' "$blobs" "$state/files.tsv" "$blobs.new" "$list.new")
  if [ -n "$differ" ]; then
    rm -f "$list.new" "$blobs.new"
    while IFS= read -r path; do
      echo "fetch-release.sh: $path: not the blob id and size the old record has for it" >&2
    done <<< "$differ"
    echo "fetch-release.sh: the record beside $dest is from an image older than sha-fe21314 and differs from" \
      "$repo@$rev at the files above. Nothing was deleted or fetched. 'fetch --force' fetches them again." >&2
    exit 1
  fi
  files=$(wc -l < "$list.new")
  want=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$list.new")
  secs=$(( (want + 4250000000) / 8500000000 ))      # 8.5 GB/s: 510.6 GB in 60 s on a DGX Spark's own NVMe (#17)
  [ "$secs" -gt 0 ] || secs=1
  echo "fetch-release.sh: the record beside $dest is from an image older than sha-fe21314, without hashes, and" \
    "matches $repo@$rev. Hashing all $files files ($((want / 1000000000)) GB) once to add them, check only:" \
    "about $secs s on a DGX Spark's own NVMe, longer on a slower disk. Nothing is deleted or downloaded."
  start=$(date +%s)
  if ! whole "$list.new"; then
    rm -f "$list.new" "$blobs.new"
    echo "fetch-release.sh: the files above are not the release's: the record stays as it was, nothing was" \
      "deleted or fetched. 'fetch --force' fetches them again." >&2
    exit 1
  fi
  mv "$list.new" "$list"
  mv "$blobs.new" "$blobs"
  rm -f "$state/files.tsv"
  echo "fetch-release.sh: the record now has every file's hash, and every hash is right ($(( $(date +%s) - start )) s)"
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

force=
case "${1:-}" in
  --check) whole; exit ;;
  --migrate) if old_record; then migrate; fi; exit ;;
  --one) one "$2"; exit ;;
  --verify) verify "$2"; exit ;;
  --force) force=1 ;;
  '') ;;
  *) echo "fetch-release.sh: want no argument, --force, --check or --migrate" >&2; exit 2 ;;
esac

if [ -z "$force" ] && old_record; then migrate; exit; fi
mkdir -p "$state" "$dest"
# The file list again when RELEASE changed, when the record has no hashes (a fetch from before the script hashed), or
# always when RELEASE names a branch rather than a commit (a branch moves)
if [ "$(cat "$state/release" 2>/dev/null)" != "$repo@$rev" ] || [ ! -s "$list" ] || [ ! -s "$blobs" ] ||
   ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
  newlist
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
