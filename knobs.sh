# The recipe's knobs as gr8's options, sourced by entrypoint.sh and bin/gr8 so every gr8 command sees the same.
#   MENTAT=0 (default): the four boxes from PEERS (their LAN addresses, head first) and, if set, IPS and IPS2 (each box's
#             fabric address on the first and second ConnectX root, in PEERS order). Nothing is announced.
#   MENTAT=1: find the other boxes through the host's mentat daemon (gr8's MENTAT=localhost) and announce the API in the
#             mentat cluster, in group GROUP (gr8-ds41-4x by default).
#   EXACT=1 (default): the exact model. EXACT=0: the two switches of gr8/docs/FIRST-BOOT.md Q3, faster and not exact.
#   SESS above 5 adds GR8_DS_SESS_DRAFTS=1, so every chat keeps drafting when more than five write (FIRST-BOOT.md Q1).
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
case "${EXACT:-1}" in
  1) ;;
  0) ds_words="$ds_words GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4" ;;
  *) echo "EXACT=$EXACT: want 1 (the exact model) or 0 (faster, not exact)" >&2; exit 2 ;;
esac
case "${SESS:-5}" in
  ''|*[!0-9]*|0*) echo "SESS=$SESS: want a number of chats, 1 or more" >&2; exit 2 ;;
  [1-5]) ;;
  *) ds_words="$ds_words GR8_DS_SESS_DRAFTS=1" ;;
esac
export EXTRA_ENV="$ds_words${EXTRA_ENV:+ $EXTRA_ENV}"
unset ds_words n
