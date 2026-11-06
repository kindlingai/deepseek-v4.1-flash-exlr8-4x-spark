#!/bin/bash
# Offline test of fetch-release.sh: a stub curl serves a small fake Hugging Face repo from a temporary folder, so no
# network and no model download. CI runs it; run it yourself with `bash tests/fetch-release.sh`. The folder (a few
# KB, ds41-fetch-test.* in the temp dir) is left for you to look at.
#
#   1. a fetch of commit A, then --check
#   2. RELEASE moved to commit B, whose files have the same sizes but other content: --check fails before the fetch,
#      the fetch replaces the changed files, keeps the unchanged one without fetching it, and deletes the file B lacks
#   3. a MODEL that holds files with no record is refused
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/fetch-release.sh
t=$(mktemp -d -t ds41-fetch-test.XXXXXX)
export HF=$t/hf
mkdir -p "$t/bin" "$HF"
cat > "$t/bin/curl" <<'STUB'
#!/bin/bash
# The API URL prints $HF/<rev>.json; a resolve URL copies $HF/<rev>/<path> to the -o file and logs it
out= url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -H|-C|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */api/models/*) r=${url##*/revision/}; cat "$HF/${r%%\?*}.json" ;;
  */resolve/*) p=${url#*/resolve/}; echo "$p" >> "$HF/fetched.log"; cat "$HF/$p" > "$out" ;;
  *) echo "curl stub: unexpected URL $url" >&2; exit 99 ;;
esac
STUB
chmod +x "$t/bin/curl"
export PATH=$t/bin:$PATH FETCH_JOBS=2

A=$(printf 'a%.0s' {1..40}) B=$(printf 'b%.0s' {1..40})
mkrev() {  # $1 = commit, then path=content pairs: the commit's files and its API answer
  local rev=$1 kv path; shift
  for kv in "$@"; do path=${kv%%=*}; mkdir -p "$(dirname "$HF/$rev/$path")"; printf %s "${kv#*=}" > "$HF/$rev/$path"; done
  (cd "$HF/$rev" && find . -type f | sed 's|^\./||' | sort | while IFS= read -r path; do
    jq -nc --arg p "$path" --argjson n "$(stat -c %s "$path")" --arg b "$(sha1sum < "$path" | cut -c1-40)" \
      '{rfilename: $p, size: $n, blobId: $b}'
  done) | jq -s '{siblings: .}' > "$HF/$rev.json"
}
mkrev "$A" weights.bin=OLD config.json=old keep/same.txt=same gone.txt=bye
mkrev "$B" weights.bin=NEW config.json=new keep/same.txt=same added.txt=hi

fail() { echo "FAIL: $* (files in $t)" >&2; exit 1; }
export MODEL=$t/release/model

# 1
export RELEASE=https://huggingface.co/example/model@$A
"$script" > /dev/null
"$script" --check || fail "check after the fetch of A"
[ "$(cat "$MODEL/weights.bin")" = OLD ] || fail "weights.bin after A"

# 2
export RELEASE=https://huggingface.co/example/model@$B
! "$script" --check || fail "check passed before the fetch of B"
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
export MODEL=$t/other/model
mkdir -p "$MODEL" && echo x > "$MODEL/weights.bin"
rc=0; err=$("$script" 2>&1) || rc=$?
[ "$rc" = 1 ] && echo "$err" | grep -q "no record" || fail "MODEL with files and no record: exit $rc: $err"

echo "fetch-release test OK ($t)"
