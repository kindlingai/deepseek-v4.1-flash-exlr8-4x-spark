#!/bin/bash
# Offline test of fetch-release.sh: a stub curl serves a small fake Hugging Face repo from a temporary folder, so no
# network and no model download. CI runs it; run it yourself with `bash tests/fetch-release.sh`. The folder (a few
# KB, ds41-fetch-test.* in the temp dir) is left for you to look at.
#
#   1. a fetch of commit A, then --check
#   2. RELEASE moved to commit B, whose files have the same sizes but other content: --check fails before the fetch,
#      the fetch replaces the changed files, keeps the unchanged one without fetching it, and deletes the file B lacks
#   3. a MODEL that holds files with no record is refused
#   4. files of the right size with the wrong content (a sparse copy of a large file, other bytes in a small one):
#      --check fails and names them, the fetch fetches those two again and nothing else
#   5. --check hashes only the files that changed since they were last hashed
#   6. a record from before the script hashed (no hashes): --check fails, the fetch hashes every file and fetches none
#   7. a download that stops part way: the fetch fails and keeps the part, and the next fetch completes the file
#   8. a file that changes while it is hashed: --check hashes it again; when it keeps changing, --check fails; when it
#      changed to wrong bytes, --check fails on the hash and the fetch fetches it again
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/fetch-release.sh
t=$(mktemp -d -t ds41-fetch-test.XXXXXX)
export HF=$t/hf
mkdir -p "$t/bin" "$HF"
cat > "$t/bin/curl" <<'STUB'
#!/bin/bash
# The API URL prints $HF/<rev>.json; a resolve URL copies $HF/<rev>/<path> to the -o file and logs it, with -C - from
# the bytes the file already holds (logged as "path offset")
out= url= cont=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -C) cont=$2; shift 2 ;;
    -H|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */api/models/*) r=${url##*/revision/}; cat "$HF/${r%%\?*}.json" ;;
  */resolve/*) p=${url#*/resolve/}; echo "$p" >> "$HF/fetched.log"
    from=0; [ "$cont" != - ] || [ ! -e "$out" ] || from=$(stat -c %s "$out")
    [ "$from" != 0 ] || : > "$out"
    echo "$p $from" >> "$HF/resumed.log"
    if [ -e "$HF/stop" ]; then tail -c +$((from + 1)) "$HF/$p" | head -c 1 >> "$out"; exit 18; fi   # "partial file"
    tail -c +$((from + 1)) "$HF/$p" >> "$out" ;;
  *) echo "curl stub: unexpected URL $url" >&2; exit 99 ;;
esac
STUB
for h in sha256sum sha1sum; do   # the real hash tools, each call logged
  printf '#!/bin/bash\necho %s >> "$HF/hashed.log"\nexec %s "$@"\n' "$h" "$(command -v "$h")" > "$t/bin/$h"
done
chmod +x "$t/bin/curl" "$t/bin/sha256sum" "$t/bin/sha1sum"

A=$(printf 'a%.0s' {1..40}) B=$(printf 'b%.0s' {1..40})
mkrev() {  # $1 = commit, then path=content pairs: the commit's files and its API answer. A *.bin file is LFS, as
  local rev=$1 kv path; shift   # Hugging Face lists it: a sha256 of the content; other files: the git blob id
  for kv in "$@"; do path=${kv%%=*}; mkdir -p "$(dirname "$HF/$rev/$path")"; printf %s "${kv#*=}" > "$HF/$rev/$path"; done
  (cd "$HF/$rev" && find . -type f | sed 's|^\./||' | sort | while IFS= read -r path; do
    n=$(stat -c %s "$path")
    if [[ $path == *.bin ]]; then
      jq -nc --arg p "$path" --argjson n "$n" --arg b "$(sha1sum < "$path" | cut -c1-40)" \
        --arg s "$(sha256sum < "$path" | cut -c1-64)" \
        '{rfilename: $p, size: $n, blobId: $b, lfs: {sha256: $s, size: $n, pointerSize: 134}}'
    else
      jq -nc --arg p "$path" --argjson n "$n" \
        --arg b "$({ printf 'blob %s\0' "$n"; cat "$path"; } | sha1sum | cut -c1-40)" \
        '{rfilename: $p, size: $n, blobId: $b}'
    fi
  done) | jq -s '{siblings: .}' > "$HF/$rev.json"
}
mkrev "$A" weights.bin=OLD config.json=old keep/same.txt=same gone.txt=bye
mkrev "$B" weights.bin=NEW config.json=new keep/same.txt=same added.txt=hi
export PATH=$t/bin:$PATH FETCH_JOBS=2

fail() { echo "FAIL: $* (files in $t)" >&2; exit 1; }
export MODEL=$t/release/model
state=$t/release/.fetch-model

# 1
export RELEASE=https://huggingface.co/example/model@$A
"$script" > /dev/null
"$script" --check || fail "check after the fetch of A"
[ "$(cat "$MODEL/weights.bin")" = OLD ] || fail "weights.bin after A"

# 2
export RELEASE=https://huggingface.co/example/model@$B
! "$script" --check 2> /dev/null || fail "check passed before the fetch of B"
: > "$HF/fetched.log"
"$script" > /dev/null
"$script" --check || fail "check after the fetch of B"
[ "$(cat "$MODEL/weights.bin")" = NEW ] || fail "weights.bin kept A's content"
[ "$(cat "$MODEL/config.json")" = new ] || fail "config.json kept A's content"
[ "$(cat "$MODEL/added.txt")" = hi ] || fail "added.txt"
[ ! -e "$MODEL/gone.txt" ] || fail "gone.txt, which B does not have, is still there"
[ "$(sort "$HF/fetched.log" | tr '\n' ' ')" = "$B/added.txt $B/config.json $B/weights.bin " ] ||
  fail "fetched: $(tr '\n' ' ' < "$HF/fetched.log") (keep/same.txt should stay)"

# 3
other=$t/other/model
mkdir -p "$other" && echo x > "$other/weights.bin"
rc=0; err=$(MODEL=$other "$script" 2>&1) || rc=$?
[ "$rc" = 1 ] && echo "$err" | grep -q "no record" || fail "MODEL with files and no record: exit $rc: $err"

# 4
: > "$MODEL/weights.bin" && truncate -s 3 "$MODEL/weights.bin"   # 3 bytes, all a hole: the size of NEW
printf NEW > "$MODEL/config.json"                                # the size of new, other bytes
rc=0; err=$("$script" --check 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "check of a sparse weights.bin and a wrong config.json: exit $rc: $err"
echo "$err" | grep -q "^MISMATCH weights.bin: .* (sha256)$" || fail "check does not name weights.bin: $err"
echo "$err" | grep -q "^MISMATCH config.json: .* (blob)$" || fail "check does not name config.json: $err"
: > "$HF/fetched.log"
"$script" > /dev/null 2>&1 || fail "fetch after the wrong files"
"$script" --check || fail "check after the fetch of the wrong files"
[ "$(cat "$MODEL/weights.bin")" = NEW ] && [ "$(cat "$MODEL/config.json")" = new ] || fail "content after the fetch"
[ "$(sort "$HF/fetched.log" | tr '\n' ' ')" = "$B/config.json $B/weights.bin " ] ||
  fail "fetched: $(tr '\n' ' ' < "$HF/fetched.log") (only the two wrong files)"

# 5
: > "$HF/hashed.log"
"$script" --check > /dev/null || fail "check of an unchanged release"
[ ! -s "$HF/hashed.log" ] || fail "check hashed unchanged files: $(tr '\n' ' ' < "$HF/hashed.log")"
printf NEW > "$MODEL/weights.bin"                                # the same bytes again: a new change time
out=$("$script" --check) || fail "check after weights.bin was written again"
[ "$out" = "OK weights.bin" ] && [ "$(cat "$HF/hashed.log")" = sha256sum ] ||
  fail "check after weights.bin was written again: hashed $(tr '\n' ' ' < "$HF/hashed.log"), said $out"

# 6
cut -f1,3 "$state/sums.tsv" > "$state/files.tsv"                # the record as the script wrote it before it hashed
mv "$state/sums.tsv" "$t/sums.tsv.before" && mv "$state/hashed.tsv" "$t/hashed.tsv.before"
rc=0; err=$("$script" --check 2>&1) || rc=$?
[ "$rc" = 1 ] && echo "$err" | grep -q "no record" || fail "check of a record with no hashes: exit $rc: $err"
: > "$HF/fetched.log" && : > "$HF/hashed.log"
"$script" > /dev/null || fail "fetch of a record with no hashes"
"$script" --check || fail "check after the fetch of a record with no hashes"
[ ! -s "$HF/fetched.log" ] || fail "fetched $(tr '\n' ' ' < "$HF/fetched.log") (every file was there)"
[ "$(sort "$HF/hashed.log" | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ')" = "sha1sum=3 sha256sum=1 " ] ||
  fail "hashed: $(sort "$HF/hashed.log" | uniq -c | tr '\n' ' ') (want each of the 4 files once)"
[ ! -e "$state/files.tsv" ] || fail "files.tsv, the old record, is still there"

# 7
: > "$MODEL/weights.bin"                                         # 0 of its 3 bytes
touch "$HF/stop" && : > "$HF/resumed.log"
! "$script" > /dev/null 2>&1 || fail "fetch passed with a download that stopped"
[ "$(cat "$MODEL/weights.bin")" = N ] && [ "$(cat "$HF/resumed.log")" = "$B/weights.bin 0" ] ||
  fail "after the stopped download: weights.bin $(cat "$MODEL/weights.bin"),"\
    "requests $(tr '\n' ' ' < "$HF/resumed.log")"
mv "$HF/stop" "$t/stop.done" && : > "$HF/resumed.log"
"$script" > /dev/null || fail "fetch after the stopped download"
[ "$(cat "$MODEL/weights.bin")" = NEW ] && [ "$(cat "$HF/resumed.log")" = "$B/weights.bin 1" ] ||
  fail "after the next fetch: weights.bin $(cat "$MODEL/weights.bin"), requests $(tr '\n' ' ' < "$HF/resumed.log")"

# 8
mv "$t/bin/sha256sum" "$t/sha256sum.logged"
cat > "$t/bin/sha256sum" <<STUB
#!/bin/bash
# The logged sha256sum; then, before it answers and one clock tick later, weights.bin gets the bytes in
# \$HF/mutate-once (once) or \$HF/mutate (at every call)
"$t/sha256sum.logged" "\$@" || exit
sleep 0.05
if [ -e "\$HF/mutate-once" ]; then
  cat "\$HF/mutate-once" > "\$MODEL/weights.bin"; mv "\$HF/mutate-once" "\$HF/mutate-once.used"
elif [ -e "\$HF/mutate" ]; then cat "\$HF/mutate" > "\$MODEL/weights.bin"; fi
STUB
chmod +x "$t/bin/sha256sum"
printf NEW > "$HF/mutate" && printf NEW > "$MODEL/weights.bin" && : > "$HF/hashed.log"
rc=0; err=$("$script" --check 2>&1) || rc=$?
[ "$rc" = 1 ] && [ "$err" = "weights.bin: changed while it was hashed, 3 times" ] &&
  [ "$(grep -c sha256sum "$HF/hashed.log")" = 3 ] ||
  fail "check of a file that changes at every hash: exit $rc, hashed $(grep -c sha256sum "$HF/hashed.log") times: $err"
mv "$HF/mutate" "$t/mutate.done"
printf BAD > "$HF/mutate-once" && printf NEW > "$MODEL/weights.bin" && : > "$HF/hashed.log"
rc=0; err=$("$script" --check 2>&1) || rc=$?
[ "$rc" = 1 ] && echo "$err" | grep -q "^MISMATCH weights.bin: .* (sha256)$" &&
  [ "$(grep -c sha256sum "$HF/hashed.log")" = 2 ] ||
  fail "check of a file that changed to BAD while it was hashed: exit $rc,"\
    "hashed $(grep -c sha256sum "$HF/hashed.log") times: $err"
[ "$(cat "$MODEL/weights.bin")" = BAD ] || fail "weights.bin after the change: $(cat "$MODEL/weights.bin")"
: > "$HF/fetched.log"
"$script" > /dev/null 2>&1 || fail "fetch after weights.bin changed to BAD"
"$script" --check > /dev/null || fail "check after the fetch of the changed weights.bin"
[ "$(cat "$MODEL/weights.bin")" = NEW ] && [ "$(cat "$HF/fetched.log")" = "$B/weights.bin" ] ||
  fail "after the fetch: weights.bin $(cat "$MODEL/weights.bin"), fetched $(tr '\n' ' ' < "$HF/fetched.log")"

echo "fetch-release test OK ($t)"
