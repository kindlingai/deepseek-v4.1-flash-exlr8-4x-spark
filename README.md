# KindlingAI: DeepSeek-V4.1-Flash EXLR8 on four DGX Sparks
**If you are an agent booting this for someone: read [AGENTS.md](AGENTS.md) first, then the Quickstart.**

_**Join our discord to learn more about KindlingAI and `gr8`: https://discord.gg/8EAvYPV2rE**_

[DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) on four DGX Sparks (GB10,
128 GB each) at TP=4, served by [gr8](https://github.com/kindlingai/gr8) from
[kindlingai/deepseek-v4.1-flash-exlr8-native](https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native):
fp8 KV, Engram and 32 chats at once, in fast mode by default. Fast mode writes faster, and its output is not
bit-identical to the exact model's.

**Our view:** DeepSeek-V4.1-Flash is best used as a reviewer, and for work that will be double-checked, because it
tends to hallucinate a lot in general. That is a model issue, not an engine or quant issue.

> Booted end to end on four boxes on 2026-11-06, from the image `sha-661d148` and this README: ready 104 s after the
> four containers started, the smoke test passed 11 of 11, and 72 of 75 right on the 75-item check in fast mode, the
> default, as in the speed row below. The speed numbers below still come from an older gr8 with the same engine
> settings, on four boxes through our own test harness, not from this image. If a step fails, tell us on Discord.

![DeepSeek-V4.1-Flash on four GB10s in fast mode: decode, prefill and concurrency](docs/card.png)

*The card is one `gr8` bench run in fast mode on 2026-11-05: gr8 `main` at `35a8f1c` with the change that became
#359, built with `DS41_MX=48` (see More numbers). A recording of several chats at once, at this recipe's defaults, is
still to come.*

Pick what to prioritize with one setting, `TUNE`, the same on all four boxes:

- `TUNE=speed` (the default): one chat writes code at 142.4-145.6 tok/s, and 32 chats run at once.
- `TUNE=context`: one chat of up to 1,048,566 tokens, 16 chats at once. Only partly measured.
- `TUNE=quality`: the exact model's output, 5 chats at once.

We recommend `TUNE=speed` or `TUNE=context`. The model hallucinates in every mode (see Our view, above). Details:
[Pick what to prioritize](#pick-what-to-prioritize), below the Quickstart.

## What you need

- Four Sparks on a 200G switch, or cabled in a ring (see Clustering).
- Docker and the NVIDIA container toolkit on each box (both come with DGX OS).
- 510.6 GB of free disk on each box: every box holds the whole release.
- TCP ports 7340 and 7341 open between the boxes.
- No other model running on any box.
- Proactive memory compaction off on each box, once, as root (it holds across reboots):

  ```bash
  echo 'vm.compaction_proactiveness = 0' > /etc/sysctl.d/90-gr8-no-proactive-compaction.conf
  sysctl -w vm.compaction_proactiveness=0
  ```

## Clustering

This recipe needs four DGX Sparks. We recommend assigning one IP address per PCIe root in the DGX
Spark. The Spark's ConnectX card shows each physical port twice, once on each PCIe root. One root carries about
110 Gb/s and both together about 196 Gb/s, and the engines use both. For a cable from the first port to the switch,
with netplan:

```yaml
# /etc/netplan/60-connectx.yaml on the first box. On box N: 10.0.0.N and 10.0.1.N.
network:
  version: 2
  ethernets:
    enp1s0f0np0:        # the first port on PCIe root 1
      addresses: [10.0.0.1/24]
      mtu: 9000
    enP2p1s0f0np0:      # the same port on PCIe root 2
      addresses: [10.0.1.1/24]
      mtu: 9000
```

Then run `sudo netplan apply` on each box. This step is optional: if each box's ConnectX port already has an address
on each PCIe root, with MTU 9000, keep those addresses and put them in `IPS` and `IPS2` in `.env`. They do not have to
be 10.0.0.N and 10.0.1.N.

Four boxes cabled in a ring without a switch also work, with `SHAPE=ring` and without `IPS` and `IPS2`: the engines
find the ports by name. Cable each box's f0 port to the next box's f1 port, and list `PEERS` in that cable order
([gr8/docs/DEPLOY.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/DEPLOY.md#how-the-boxes-find-each-other)).

We also recommend that you run [`mentat`](https://github.com/kindlingai/mentat) (`ghcr.io/kindlingai/mentat`) for
your cluster for zero-IP configuration. `mentat` will allow this recipe to autoconfigure itself with other nodes in
your cluster. On each box:

```bash
docker run -d --name mentat --network host --restart unless-stopped ghcr.io/kindlingai/mentat:0.27.0
```

Then start the recipe with `MENTAT=1` in place of `PEERS`, `IPS` and `IPS2`.

To run without `mentat`, specify the four nodes' 10G IP addresses using `PEERS` (head first), and the matching
ConnectX IP addresses with `IPS` (PCIe root 1) and `IPS2` (PCIe root 2), in the same order.

## Quickstart

First, fetch the release on every box. Each box needs all 604 files (510.6 GB). The fetch resumes where it left off
if you run it again, checks every file against the hash Hugging Face lists for it, and fetches a wrong file again:

```bash
docker run --rm --read-only -v ds41-release:/var/lib/gr8/release \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest fetch
```

The download is the slow part. In our run one box alone fetched the whole 510.6 GB release in 74 minutes (4,420 s as
the fetch reported it, 0.92 Gb/s on average). Four boxes at once got about 0.2 Gb/s each on the three boxes we logged
(the fourth was not logged), about 0.8 Gb/s in all if the fourth matched: at that rate the release takes about 5.7 hours
on four boxes (computed, not timed). So fetch on one box, then copy the whole `ds41-release` volume, the release and the
`.fetch-*` record beside it, to the other three over the ConnectX ports.

To copy, first run `docker volume create ds41-release` on each of the other three. Then, on the box that fetched, run
the commands below as root. Root on this box must be able to ssh to root on the other three. The addresses are boxes
2 to 4's ConnectX addresses on PCIe root 1 in the netplan example above (their `IPS` values): use yours. The copy runs
8 `rsync` streams to each box at once, and prints a `FAILED` line for each stream that fails:

```bash
V=$(docker volume inspect ds41-release --format '{{ .Mountpoint }}') && cd "$V" &&
  find . -type f -printf '%P\n' > /tmp/ds41-files && split -n r/8 -d /tmp/ds41-files /tmp/ds41-part. &&
  for box in 10.0.0.2 10.0.0.3 10.0.0.4; do
    for part in /tmp/ds41-part.*; do
      ( rsync -a -W --files-from="$part" "$V/" "root@$box:$V/" || echo "FAILED: $box $part" ) &
    done
  done; wait
for box in 10.0.0.2 10.0.0.3 10.0.0.4; do ssh "root@$box" du -sb "$V"; done   # each: at least 510597801105 bytes
```

In our run that copy, to all three at once, took about 4.5 minutes (about 1.9 GB/s to each box; each box already
held about 27 GB from an earlier try): one fetch and the copy took about 80 minutes in all, against about 5.7 hours
for four fetches at once. A copy is whole when no `FAILED` line printed and its volume holds at least 510597801105
bytes. Then run the fetch on each of the other three: it hashes every file and fetches only the wrong ones. We have
not timed that hash check yet. A sparse copy, with every file at its full size but only some of its bytes written, is
not the whole release; the fetch finds those files and fetches them again.

After you update the image, run the fetch once more on every box: it checks every file and downloads only what is
wrong or missing.

Then run the published image on all four boxes with the same settings. Without `mentat`, replace `<head>`, `<box2>`,
`<box3>` and `<box4>` with the four boxes' 10G LAN addresses, the same list on every box. The head is the first box in
`PEERS`: it serves the API on port 8100. `IPS` and `IPS2` are the ConnectX addresses from the netplan example above:
use yours.

```bash
docker run -d --name ds41-4x-spark --gpus all --network host --pid host --device /dev/infiniband \
  --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
  --security-opt no-new-privileges --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
  -e PEERS=<head>,<box2>,<box3>,<box4> \
  -e IPS=10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4 -e IPS2=10.0.1.1,10.0.1.2,10.0.1.3,10.0.1.4 \
  -v ds41-release:/var/lib/gr8/release -v ds41-home:/var/lib/gr8/home \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest
docker logs -f ds41-4x-spark     # on the head: ready at "serving: http://..."
```

With `mentat` running, replace the `PEERS`, `IPS` and `IPS2` settings with `-e MENTAT=1`: then the head is the box with
the lowest address. A container stops at once, and says why, if the release on its box is not whole. The boxes wait for
each other for 10 minutes (gr8's `JOIN_TIMEOUT`, 600 s), so start all four within that time. Expect about 2 minutes to
ready: in our run the head printed `serving:` 104 s after the four containers started.

The head serves an OpenAI-compatible API on port 8100. The model's name is `deepseek-v4.1-flash`:

```bash
curl -s localhost:8100/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "deepseek-v4.1-flash",
  "messages": [{"role": "user", "content": "Write a haiku about a small computer."}],
  "max_tokens": 4096
}'
```

A request that does not set a reasoning effort runs at effort `low`.

```bash
docker exec ds41-4x-spark gr8 ds41 smoke   # on the head: checks the API, tool calls included
docker stop ds41-4x-spark && docker rm ds41-4x-spark   # on every box
```

`:latest` follows `main`. Each commit is also published as `sha-<commit>`, and each tag under its name.

## Run it with compose

`compose.yaml` runs the same image with the same settings and reads `PEERS` and the knobs from `.env`. It uses the
same `ds41-release` volume as the commands above. On every box:

```bash
git clone --recurse-submodules https://github.com/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark
cd deepseek-v4.1-flash-exlr8-4x-spark
cp .env.example .env          # set PEERS, IPS and IPS2: the same file on every box
docker compose run --rm gr8 fetch
docker compose up -d
docker compose logs -f
```

Fetch first: compose restarts a container that stops with an error, so without the whole release it starts and stops
again until the fetch is done.

`docker compose up -d --build` builds the image on the box instead. CI builds every push
(`.github/workflows/image.yml`).

## Knobs

In `.env` next to `compose.yaml` (see `.env.example`), or with `docker run -e`, the same on every box:

| knob | default | |
|---|---|---|
| `PEERS` | none | The four boxes' 10G LAN addresses, head first. Required unless `MENTAT=1`. |
| `IPS`, `IPS2` | none | Each box's ConnectX address on PCIe root 1 and root 2, in `PEERS` order (see Clustering). |
| `TUNE` | `speed` | `speed`: fast mode, faster and not bit-identical to the exact model's output. `context`: fast mode, one chat of up to 1,048,566 tokens. `quality`: the exact model's output. See Pick what to prioritize. `EXACT=1`, the older name, is now `TUNE=quality`. |
| `CAP` | `327680`; `1048576` with `TUNE=context`; `262144` with `TUNE=quality` | The longest chat in tokens, prompt and reply together. Every chat slot gets this much KV at boot. A request holds at most `CAP` less 10 tokens (327,670; 1,048,566 with `TUNE=context`; 262,134 with `TUNE=quality`). |
| `SESS` | `32`; `16` with `TUNE=context`; `5` with `TUNE=quality` | Chats at once, 1 to 32. A chat that arrives when every slot is busy waits. Above 5, the image adds `GR8_DS_SESS_DRAFTS=1`: each chat drafts fewer tokens as more chats write, and none when more than 24 write at once. |
| `MENTAT` | `0` | `1`: the boxes find each other and their ConnectX addresses through the host's `mentat` daemon, and register the API, in group `GROUP` (`gr8-ds41-4x`). |

The image pins the release to the Hugging Face commit measured below,
[`9807632`](https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native/tree/98076325aaa2c8dfec6095536d69c47bfcfbb3dc).
Set `RELEASE` in `.env` to fetch another (`https://huggingface.co/<org>/<repo>@<commit>`). The fetch then replaces
each file whose content differs (it compares Hugging Face's blob ids) and keeps the rest, and `up` starts only when the
volume holds the whole release `RELEASE` names, with every file at its size and hash. The check hashes only the files
that changed since they were last hashed. Engram's token map is
written when the image is built, from two files of
[DeepSeek-V4.1-Flash-1017 at `1bae0e1`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/tree/1bae0e1088993b9b82de08f59de5be5a34e42170)
and the release's tokenizer, and the build stops unless it matches the map the engine checks at boot.

You can set any other `gr8` option in `.env` too: [gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/KNOBS.md)
lists them, and [gr8/docs/DEEPSEEK-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/DEEPSEEK-BOOT.md)
covers DeepSeek-V4.1-Flash. Engine settings go in `EXTRA_ENV`, as `NAME=value` pairs separated by spaces
(`EXTRA_ENV="A=1 B=2"`). The image sets `TP=4`, Engram and the `TUNE` value's settings (`Dockerfile`, `knobs.sh`). The
KV cache is always fp8. The image's engine is built with `DS41_MX=48`: a decode step holds 48 rows instead of gr8's
default 32, so a step can verify 6 rows for each of 8 chats
([gr8/engine/runtime/build_m4.sh](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/engine/runtime/build_m4.sh)).

## Pick what to prioritize

`TUNE` picks one of three sets of settings (`knobs.sh`). A `CAP` or `SESS` you set yourself keeps your value, and
settings in `EXTRA_ENV` come after the recipe's own. Above 5 chats, every value also gets `GR8_DS_SESS_DRAFTS=1` (see
Knobs).

| `TUNE` | sets | you get | you give up | measured |
|---|---|---|---|---|
| `speed` (default) | fast mode: `GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4 GR8_DS41_HEAD_MX=1 GR8_DS_ATTN_TC_MF=2 GR8_DS_ATTN_TC_TILE=1 GR8_DS_MHC_ROW_SHARD=1`, `SESS=32`, `CAP=327680` | One chat writes code / prose / structured at 142.4-145.6 / 83.5-84.6 / 159.5-161.6 tok/s. 8 chats together write 210.7-228.3 tok/s. 32 chats of up to 327,670 tokens. | Replies are not bit-identical to the exact model's. 72 of 75 right on FIRST-BOOT.md's 75-item check, against the exact model's 73. | On gr8 `main` at `35a8f1c` with the change that became #359, not on this image (see More numbers). |
| `context` | fast mode's six switches, `GR8_DS_CACHE_MIB=2048` (the prefix cache at half its default), `SESS=16`, `CAP=1048576` | One chat of up to 1,048,566 tokens. A 1,031,542-token prompt reads in about 417 s. 9.8-10.0 GiB free a box at ready. | 16 chats at once, not 32. Recall at 1M found all 3 hidden facts in 2 of 7 prompts. At 2,048 MiB, only the last 1M chat stays in the prefix cache. | Partly: [FIRST-BOOT.md Q2](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q2-how-long-can-one-chat-be), on an earlier gr8 build with only Q3's two switches, not this image's `DS41_MX=48` build. The memory and read time are from that build. Speed at 1M is not measured. |
| `quality` | gr8's launcher defaults (none of fast mode's switches), `SESS=5`, `CAP=262144` | The exact model's output. 73 of 75 right, in each of three runs. | One chat writes code / prose / structured at 104.6-105.9 / 61.7-62.0 / 126.2-126.9 tok/s. 5 chats at once, of up to 262,134 tokens. | On older gr8 builds, not on this image's `DS41_MX=48` build (see More numbers). |

### `speed` against `quality`

Fast mode (`TUNE=speed`, the default, and `TUNE=context`) turns on the switches of
[gr8/docs/FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#3-deepseek-v41-flash-ds41-speed-against-exactness)
Q3 (`GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4`) and Q4 (`GR8_DS41_HEAD_MX=1`), which change
the output. It also turns on three prefill settings of
[gr8/docs/ENV.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/ENV.md):
`GR8_DS_ATTN_TC_MF=2`, `GR8_DS_ATTN_TC_TILE=1` and `GR8_DS_MHC_ROW_SHARD=1`. Its replies are not bit-identical to the
exact model's: the same prompt can get a different reply. `TUNE=quality` runs gr8's launcher defaults, which give the
exact model's output. In FIRST-BOOT.md, Q3's two switches took the 75-item check from 73 to 71 right, and Q4's head,
added to them, brought it to 72.

| | `TUNE=speed` (default) | `TUNE=quality` |
|---|---|---|
| output | not bit-identical to the exact model's | the exact model's |
| FIRST-BOOT.md's 75-item check | 72 of 75 right, on each of two boots | 73 of 75 right, in each of three runs |
| one chat writing: code / prose / structured | 142.4-145.6 / 83.5-84.6 / 159.5-161.6 tok/s | 104.6-105.9 / 61.7-62.0 / 126.2-126.9 tok/s |
| prompt reading, cold: 8K / 32K / 128K | 3,655-4,463 / 4,453-4,903 / 4,449-4,612 tok/s | 3,197-3,700 / 3,721-4,001 / 3,741-3,815 tok/s |
| 8 chats at once, all together | 210.7-228.3 tok/s | 137.8-145.9 tok/s, 3 of the 8 waiting for a slot |
| chats at once, unless `SESS` is set | 32 | 5 |
| longest request, unless `CAP` is set | 327,670 tokens | 262,134 tokens |

The two columns come from different gr8 builds and boots: the `TUNE=quality` column is an older build with 5 chat slots.
So the table does not show how much of the difference fast mode alone makes. More numbers names both builds.

### Chat slots and chat length

From [gr8/docs/FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#2-deepseek-v41-flash-ds41-how-many-chats-and-how-long),
measured on four GB10 boxes with an earlier gr8 build. Q3's switches were on, the rest of fast mode was not.

| change | you gain | you give up | measured |
|---|---|---|---|
| `SESS=5` | With 8 chats, the 5 that run write 68-69 tok/s each, against 51-56 when 10 slots let all 8 run. The total stays at about 235-275 tok/s from 8 chats up. Each 262,144-token slot dropped frees about 0.35 GiB a box at ready. | Chats beyond 5 wait for a slot. With 16 chats, 11 wait, and the first word comes in 5.4-5.5 s, against 4.2-4.4 s with 10 or 16 slots. | [Q1](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q1-how-many-chats-at-once), 5, 10 and 16 slots; 32 slots were not part of Q1 |
| `CAP=1048576 SESS=16` (`TUNE=context`) | One chat can hold 1,048,566 tokens. | A 1,031,542-token prompt takes about 417 s to read. Recall at 1M found all 3 hidden facts in 2 of 7 prompts. 9.8-10.0 GiB free a box at ready. | [Q2](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q2-how-long-can-one-chat-be), 16 slots, `GR8_DS_CACHE_MIB=2048`; 32 slots at 1M were not tested |

## The prefix cache

Each box keeps snapshots of recent prompts in memory, up to 4,096 MiB (`GR8_DS_CACHE_MIB`; `TUNE=context` sets 2,048).
A later prompt that starts the same way, such as an agent's next turn, reads only the part after the snapshot. The
cache is not kept on disk, so a restart empties it.

## More numbers

The card above is one `gr8` bench run on four boxes in fast mode, stored in `kindling.json`. Regenerate it with
`python3 gr8/bench/bench.py kindling REPORT.json --out kindling.json --config-id tp4`.

### Fast mode

Two boots on 2026-11-05, with this recipe's fast-mode settings: Engram, fast mode's switches, 32 chat slots and `CAP`
327,680. The engine was gr8 `main` at
[`35a8f1c`](https://github.com/kindlingai/gr8/commit/35a8f1c771991a87b0c6308006b74ce70faf0378) with the change that
became gr8 #359, built with `DS41_MX=48`. The image builds a later `main`,
[`5381433`](https://github.com/kindlingai/gr8/commit/5381433c940b51223f8287f93b0c484c806207e9), which contains both
and 39 other later commits, and it sets the same engine settings. These numbers have not been measured on that build.
The rows are the four runs, two on each boot, as a range:

| | |
|---|---|
| decode, one stream: code / prose / structured | 142.4-145.6 / 83.5-84.6 / 159.5-161.6 tok/s |
| prefill, cold: 8K / 32K / 128K prompt | 3,655-4,463 / 4,453-4,903 / 4,449-4,612 tok/s |
| all streams together: 1 / 2 / 4 / 8 | 105.7-109.1 / 142.5-150.4 / 161.3-175.4 / 210.7-228.3 tok/s |
| first word after a 128K prompt | 28.5-29.5 s |
| a fact hidden in a 128K prompt | found in each of the four runs |
| quality | 72 of 75 on FIRST-BOOT.md's 75-item check, one run on each boot |
| the release | 510.6 GB in 604 files, on every box |

### `TUNE=quality`

One boot on 2026-11-02 of the branch that was merged as gr8 `main` at
[`40a91f5`](https://github.com/kindlingai/gr8/commit/40a91f57beac69a752ab15b6e8f4e1c24d70c7a4). Its engine, launcher and
front end are the same as `40a91f5`'s, built with gr8's default 32 rows a step. It used the launcher's defaults and
Engram: exact output, 5 chat slots, `CAP` 262,144. Its longest request was 163,830 tokens, because it came before gr8
#325. `main` now allows 262,134. `main`'s launcher has since added three defaults that this boot ran without:
`GR8_DEC_BK` equal to `CAP` (this boot: 16384), `GR8_DS_COMP_FP4=1` and `GR8_S2_DECODE_PF=1024`. `TUNE=quality` on
this image's `DS41_MX=48` build has not been measured.

The first four rows are that boot's two runs, as a range:

| | |
|---|---|
| decode, one stream: code / prose / structured | 104.6-105.9 / 61.7-62.0 / 126.2-126.9 tok/s |
| prefill, cold: 8K / 32K / 128K prompt | 3,197-3,700 / 3,721-4,001 / 3,741-3,815 tok/s |
| all streams together: 1 / 2 / 4 / 8 | 88.9-91.1 / 110.0-113.6 / 119.7-131.2 / 137.8-145.9 tok/s |
| first word after a 128K prompt | 34.3-35.1 s |
| quality, on a later boot of `main` at b10aae4 | 73 of 75 in each of three runs of FIRST-BOOT.md's 75-item check, exact output |

The boxes were four DGX Sparks on one switch, for both. Their CPUs were kept out of deep idle (PM QoS
`cpu_dma_latency` 0), and memory was compacted before each boot. Both are box settings outside gr8. The boots went
through our own test harness, not this image.

## For your agent

- [AGENTS.md](AGENTS.md): how to boot this recipe and check that it serves, every knob, and what each `TUNE` value
  sets.
- [gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/KNOBS.md): every
  `gr8` option.
- [gr8/docs/DEEPSEEK-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/DEEPSEEK-BOOT.md)
  and [gr8/docs/FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md):
  the DeepSeek boot, and the measured trade-offs.
- [kindling.json](kindling.json): the numbers on the card, as data.
