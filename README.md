# KindlingAI: DeepSeek-V4.1-Flash EXLR8 on four DGX Sparks

_**Join our discord to learn more about KindlingAI and `gr8`: https://discord.gg/8EAvYPV2rE**_

[DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) on four DGX Sparks (GB10,
128 GB each) at TP=4, served by [gr8](https://github.com/kindlingai/gr8) from
[kindlingai/deepseek-v4.1-flash-exlr8-native](https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native):
fp8 KV, Engram, five chats at once, and the exact model's output.

> Not yet run end to end. The image builds and passes its no-GPU smoke test on a test box (CI has not run yet), and the
> numbers below come from gr8 on four boxes through our own test harness. This recipe's Quickstart has not yet been run
> on four clean boxes. If a step fails, tell us on Discord.

![DeepSeek-V4.1-Flash on four GB10s: decode, prefill and concurrency](docs/card.png)

*A recording of several chats at once, at this recipe's defaults, is still to come.*

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

Then run `sudo netplan apply` on each box. Four boxes cabled in a ring without a switch also work, with `SHAPE=ring`
and without `IPS` and `IPS2`: the engines find the ports by name. Cable each box's f0 port to the next box's f1 port,
and list `PEERS` in that cable order
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

First, fetch the release on every box. Each box needs all 604 files (510.6 GB), and the fetch resumes where it left
off if you run it again:

```bash
docker run --rm --read-only -v ds41-release:/var/lib/gr8/release \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest fetch
```

Then run the published image on all four boxes with the same settings. Without `mentat`, this names the boxes as in
the netplan example above:

```bash
docker run -d --name ds41-4x-spark --gpus all --network host --pid host --device /dev/infiniband \
  --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
  --security-opt no-new-privileges --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
  -e PEERS=192.168.100.10,192.168.100.11,192.168.100.12,192.168.100.13 \
  -e IPS=10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4 -e IPS2=10.0.1.1,10.0.1.2,10.0.1.3,10.0.1.4 \
  -v ds41-release:/var/lib/gr8/release -v ds41-home:/var/lib/gr8/home \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest
docker logs -f ds41-4x-spark     # on the head: ready at "serving: http://..."
```

With `mentat` running, replace the three addresses with `-e MENTAT=1`. A container stops at once, and says why, if
the release on its box is not whole. The boxes wait for each other for 10 minutes (gr8's `JOIN_TIMEOUT`, 600 s), so
start all four within that time.

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
| `CAP` | `262144` | The longest chat in tokens, prompt and reply together. Every chat slot gets this much KV at boot. A request holds at most `CAP` less 10 tokens (262,134). |
| `SESS` | `5` | Chats at once. A chat that arrives when every slot is busy waits. Above 5, the image adds `GR8_DS_SESS_DRAFTS=1`, so every chat keeps drafting. |
| `EXACT` | `1` | `1`: the exact model's output. `0`: faster, not exact (see What you can trade). |
| `MENTAT` | `0` | `1`: the boxes find each other and their ConnectX addresses through the host's `mentat` daemon, and register the API, in group `GROUP` (`gr8-ds41-4x`). |

The image pins the release to the Hugging Face commit measured below,
[`9807632`](https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native/tree/98076325aaa2c8dfec6095536d69c47bfcfbb3dc).
Set `RELEASE` in `.env` to fetch another (`https://huggingface.co/<org>/<repo>@<commit>`). The fetch then replaces
each file whose content differs (it compares Hugging Face's blob ids) and keeps the rest, and `up` starts only when the
volume holds the whole release `RELEASE` names. Engram's token map is
written when the image is built, from two files of
[DeepSeek-V4.1-Flash-1017 at `1bae0e1`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/tree/1bae0e1088993b9b82de08f59de5be5a34e42170)
and the release's tokenizer, and the build stops unless it matches the map the engine checks at boot.

You can set any other `gr8` option in `.env` too: [gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/KNOBS.md)
lists them, and [gr8/docs/DEEPSEEK-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/DEEPSEEK-BOOT.md)
covers DeepSeek-V4.1-Flash. Engine settings go in `EXTRA_ENV`, as `NAME=value` pairs separated by spaces
(`EXTRA_ENV="A=1 B=2"`). The image sets `TP=4`
and Engram (`Dockerfile`, `knobs.sh`). The KV cache is always fp8.

## What you can trade

From [gr8/docs/FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#2-deepseek-v41-flash-ds41-how-many-chats-and-how-long),
measured on four GB10 boxes with gr8. Rows marked "faster, not exact" were measured with `EXACT=0`'s two switches on,
so their tok/s are higher than the same change gives at `EXACT=1`.

| change | you gain | you give up | measured |
|---|---|---|---|
| `EXACT=0` | Faster writing. Long replies: code +41-42%, prose +50-52%. Short replies: code +21-23%, prose +51%. | The output is no longer the exact model's. The 75-item check went from 73 to 71 right. | [Q3](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q3-faster-writing-for-a-small-quality-loss), two builds of `main` |
| `SESS=10` or `16` | Fewer chats wait for a free slot: with 16 chats, 11 wait at 5 slots, 6 at 10 and none at 16. The first word then comes in 4.2-4.4 s, against 5.4-5.5 s with 5 slots. | Each chat writes slower: with 8 chats, 51-56 tok/s each against 68-69. The total stays at about 235-275 tok/s from 8 chats up. About 0.35 GiB a box for each slot. | [Q1](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q1-how-many-chats-at-once), faster, not exact |
| `CAP=1048576` | One chat can hold 1,048,566 tokens. | A 1,031,542-token prompt takes about 417 s to read. Recall at 1M found all 3 hidden facts in 2 of 7 prompts. 9.8-10.0 GiB free a box at ready, with 16 slots. | [Q2](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q2-how-long-can-one-chat-be), 16 slots, `GR8_DS_CACHE_MIB=2048`, faster, not exact |
| `EXTRA_ENV=GR8_DS41_HEAD_MX=1` | New text decodes 2.4% faster. | 13 of 75 answers changed. The check went from 71 to 72 right. | [Q4](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md#q4-a-smaller-output-head), faster, not exact |

## The prefix cache

Each box keeps snapshots of recent prompts in memory, up to 4,096 MiB (`GR8_DS_CACHE_MIB`). A later prompt that
starts the same way, such as an agent's next turn, reads only the part after the snapshot. The cache is not kept on
disk, so a restart empties it.

## More numbers

The card above is one `gr8` bench run on four boxes, stored in `kindling.json`. Regenerate it with
`python3 gr8/bench/bench.py kindling REPORT.json --out kindling.json --config-id tp4`.

That boot ran the branch that was merged as gr8 `main` at
[`40a91f5`](https://github.com/kindlingai/gr8/commit/40a91f57beac69a752ab15b6e8f4e1c24d70c7a4). Its engine, launcher and
front end are the same as `40a91f5`'s. It used the launcher's defaults and Engram: the same settings as this recipe
(exact output, 5 chat slots, `CAP` 262,144), on an older `main` than the image builds. Its longest request was 163,830
tokens, because it came before gr8 #325. `main` now allows 262,134.

The first four rows are that boot's two runs, as a range:

| | |
|---|---|
| decode, one stream: code / prose / structured | 104.6-105.9 / 61.7-62.0 / 126.2-126.9 tok/s |
| prefill, cold: 8K / 32K / 128K prompt | 3,197-3,700 / 3,721-4,001 / 3,741-3,815 tok/s |
| all streams together: 1 / 2 / 4 / 8 | 88.9-91.1 / 110.0-113.6 / 119.7-131.2 / 137.8-145.9 tok/s |
| first word after a 128K prompt | 34.3-35.1 s |
| quality, on a later boot of `main` at b10aae4 | 73 of 75 in each of three runs of FIRST-BOOT.md's 75-item check, exact output |
| the release | 510.6 GB in 604 files, on every box |

The boxes were four DGX Sparks on one switch. Their CPUs were kept out of deep idle (PM QoS `cpu_dma_latency`
0), and memory was compacted before each boot. Both are box settings outside gr8. The boots went through our own test
harness, not this image.

## For your agent

- [AGENTS.md](AGENTS.md): where the settings are, in two lines.
- [gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/KNOBS.md): every
  `gr8` option.
- [gr8/docs/DEEPSEEK-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/DEEPSEEK-BOOT.md)
  and [gr8/docs/FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/5381433c940b51223f8287f93b0c484c806207e9/docs/FIRST-BOOT.md):
  the DeepSeek boot, and the measured trade-offs.
- [kindling.json](kindling.json): the numbers on the card, as data.
