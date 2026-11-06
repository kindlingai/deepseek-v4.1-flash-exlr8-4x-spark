# The recipe's knobs as gr8's options, sourced by entrypoint.sh and bin/gr8 so every gr8 command sees the same.
#   MENTAT=0 (default): the four boxes from PEERS (their LAN addresses, head first) and, if set, IPS and IPS2 (each box's
#             fabric address on the first and second ConnectX root, in PEERS order). Nothing is announced.
#   MENTAT=1: find the other boxes through the host's mentat daemon (gr8's MENTAT=localhost) and announce the API in the
#             mentat cluster, in group GROUP (gr8-ds41-4x by default).
#   EXACT=0 (default): fast mode, the settings measured in README.md. FIRST-BOOT.md Q3's two switches and Q4's output
#             head, which change the output; three prefill settings of gr8/docs/ENV.md (GR8_DS_ATTN_TC_MF=2,
#             GR8_DS_ATTN_TC_TILE=1, GR8_DS_MHC_ROW_SHARD=1); and, unless set, SESS=32 and CAP=327680. The image's
#             engine is built with DS41_MX=48 (Dockerfile), so a step holds 48 rows.
#   EXACT=1: the exact model, with gr8's launcher defaults and, unless set, SESS=5 and CAP=262144.
#   SESS above 5 adds GR8_DS_SESS_DRAFTS=1: each chat drafts fewer tokens as more chats write (FIRST-BOOT.md Q1), and
#             on the image's 48-row build none when more than 24 write (gr8/docs/ENV.md).
# Engram is always on, from the token map in ENGRAM_PREFIX (entrypoint.sh). Settings already in EXTRA_ENV are kept, after
# these.
case "${MENTAT:-0}" in
  0) unset MENTAT
     n=$(tr , '\n' <<< "${PEERS:-}" | grep -c .) || true
     [ "$n" = 4 ] || { echo "PEERS=${PEERS:-}: want the four boxes' LAN addresses, head first, the same on every box (or MENTAT=1)" >&2; exit 2; } ;;
  1) unset PEERS; export MENTAT=localhost ;;
  localhost) unset PEERS ;;
  *) echo "MENTAT=$MENTAT: want 0 (the boxes in PEERS) or 1 (register with the mentat cluster)" >&2; exit 2 ;;
esac
ds_words="GR8_DS_ENGRAM=1 GR8_DS_ENGRAM_PREFIX=${ENGRAM_PREFIX:?}"
case "${EXACT:-0}" in
  0) ds_words="$ds_words GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4 GR8_DS41_HEAD_MX=1"
     ds_words="$ds_words GR8_DS_ATTN_TC_MF=2 GR8_DS_ATTN_TC_TILE=1 GR8_DS_MHC_ROW_SHARD=1"
     SESS=${SESS:-32} CAP=${CAP:-327680} ;;
  1) SESS=${SESS:-5} CAP=${CAP:-262144} ;;
  *) echo "EXACT=$EXACT: want 0 (fast mode, not exact) or 1 (the exact model)" >&2; exit 2 ;;
esac
export SESS CAP
case "$SESS" in
  ''|*[!0-9]*|0*) echo "SESS=$SESS: want a number of chats, 1 or more" >&2; exit 2 ;;
  [1-5]) ;;
  *) ds_words="$ds_words GR8_DS_SESS_DRAFTS=1" ;;
esac
export EXTRA_ENV="$ds_words${EXTRA_ENV:+ $EXTRA_ENV}"
unset ds_words n
