# KindlingAI: DeepSeek-V4.1-Flash EXLR8 on four DGX Sparks

If you are an agent booting this for someone, read [AGENTS.md](AGENTS.md) first, then the Quickstart.

_**Join our discord to learn more about KindlingAI and `gr8`: https://discord.gg/8EAvYPV2rE**_

DeepSeek-V4.1-Flash (DeepSeek's release [DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017)) on four DGX Sparks (GB10,
128 GB each) at TP=4, served by [gr8](https://github.com/kindlingai/gr8) from
[kindlingai/deepseek-v4.1-flash-exlr8-native](https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native).

![DeepSeek-V4.1-Flash on four GB10s in fast mode: decode, prefill and concurrency](docs/card.png)

## Results

This image (`{{IMAGE_TAG}}`, gr8 [`{{GR8_SHA7}}`](https://github.com/kindlingai/gr8/commit/{{GR8_SHA}})), in fast mode
(`TUNE=speed`, the default), on four DGX Sparks (GB10, 128 GB each) {{TOPOLOGY: on one 200G switch | in a ring}}, on
{{DATE}}. Every speed is in tokens per second (tok/s).

| | tok/s |
|---|---|
| prefill: 32K / 128K prompt | {{PF_32K}} / {{PF_128K}} |
| decode, one stream: {{SHORT_PROMPT}}-token / {{LONG_PROMPT}}-token prompt | {{DEC1_SHORT}} / {{DEC1_LONG}} |
| total decode: 4 / 8 / 16 / 32 streams ({{CONC_PROMPT}}-token prompts) | {{AGG_4}} / {{AGG_8}} / {{AGG_16}} / {{AGG_32}} |

| | |
|---|---|
| first token after a 32K / 128K prompt | {{TTFT_32K}} s / {{TTFT_128K}} s |
| longest chat (prompt and reply) | {{MAX_CTX}} tokens |
| ready after `up -d` (gen cache written) | {{BOOT_S}} s |
| switch from GLM-5.3 to this recipe | {{SWITCH_S}} s |

Fast mode's replies are not bit-identical to the exact model's (`TUNE=quality`). On the 75-item quality check of gr8's
[FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/{{GR8_SHA}}/docs/FIRST-BOOT.md#3-deepseek-v41-flash-ds41-speed-against-exactness),
this build scored {{QEVAL}} of 75. Other hardware and other box counts were not measured.

### How we measure

- The image above, started as this README shows, with no other settings unless the row says so.
- No tracing or per-stage timing on the measured requests.
- A number that compares two settings comes from paired runs: both settings on the same boxes, each on a fresh boot,
  in both orders.
- Every speed is tok/s. Every decode number gives its prompt length.
- Each number is {{STAT: the mean | the range}} of {{N}} runs. The raw runs and the method are in gr8's
  [DEEPSEEK.md](https://github.com/kindlingai/gr8/blob/{{GR8_SHA}}/docs/DEEPSEEK.md#how-we-measure).

## What you need

- Four Sparks on a 200G switch, or cabled in a ring (see Clustering).
- Docker and the NVIDIA container toolkit on each box (both come with DGX OS).
- 510.6 GB of free disk on each box: every box holds the whole release. The gen cache that `.env.example` turns on needs
  about 80 GB more (up to about 160 GB once a second cache key exists, for example after a new image or a `TUNE` change
  between `quality` and `speed` or `context`; see "Switch between this and GLM-5.3").
- TCP ports 7340 and 7341 open between the boxes.
- No other model running on any box.
- Proactive memory compaction off on each box, once, as root (it holds across reboots):

  ```bash
  echo 'vm.compaction_proactiveness = 0' > /etc/sysctl.d/90-gr8-no-proactive-compaction.conf
  sysctl -w vm.compaction_proactiveness=0
  ```

## Clustering

Give each box one address per PCIe root. The Spark's ConnectX card shows each physical port twice, once on each PCIe
root, and the engines use both. For a cable from the first port to the switch, with netplan:

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

The two port names above are the usual ones on a DGX Spark. `ip -br link` lists the names on your box. Two kinds of
address are in play: the 10G LAN address (`PEERS`) is the box's normal network address, which you reach it by; the
ConnectX addresses (`IPS`, `IPS2`) are on the 200G ports, one for each PCIe root. MTU 9000 needs a switch and cables that
carry it.

Then run `sudo netplan apply` on each box. If each box's ConnectX port already has an address on each PCIe root, with
MTU 9000, skip this step and put those addresses in `IPS` and `IPS2`.

Four boxes cabled in a ring without a switch also work, with `SHAPE=ring` and without `IPS` and `IPS2`. Cable each
box's f0 port to the next box's f1 port, and list `PEERS` in that cable order
([gr8/docs/DEPLOY.md](https://github.com/kindlingai/gr8/blob/4ed9e7bed53d6ed23ba1c4a32c993ccc3850af96/docs/DEPLOY.md#how-the-boxes-find-each-other)).

With [`mentat`](https://github.com/kindlingai/mentat) running on each box, the recipe finds the other boxes and their
ConnectX addresses by itself. On each box:

```bash
docker run -d --name mentat --network host --restart unless-stopped ghcr.io/kindlingai/mentat:0.27.0
```

What to set, by how the four boxes are joined:

| your boxes | set | leave out |
|---|---|---|
| on a switch, with `mentat` | `MENTAT=1` | `PEERS`, `IPS`, `IPS2` |
| on a switch, without `mentat` | `PEERS` (10G LAN addresses, head first), `IPS`, `IPS2` | |
| in a ring, without a switch | `PEERS` in cable order, `SHAPE=ring` | `IPS`, `IPS2` |

## Quickstart

First, fetch the release on every box. Each box needs all 604 files (510.6 GB). The fetch resumes where it left off
if you run it again, checks every file against the hash Hugging Face lists for it, and fetches a wrong file again:

```bash
docker run --rm --read-only -v ds41-release:/var/lib/gr8/release \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest fetch
```

Then run the published image on all four boxes with the same settings. Without `mentat`, replace `<head>`, `<box2>`,
`<box3>` and `<box4>` with the four boxes' 10G LAN addresses, the same list on every box. The head is the first box in
`PEERS`: it serves the API on port 8100. `IPS` and `IPS2` are the ConnectX addresses from the netplan example above:
use yours.

```bash
docker run -d --name ds41-4x-spark --gpus all --network host --pid host --device /dev/infiniband \
  --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
  --security-opt no-new-privileges --security-opt seccomp=<dir>/seccomp-iouring.json \
  --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
  -e PEERS=<head>,<box2>,<box3>,<box4> \
  -e IPS=10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4 -e IPS2=10.0.1.1,10.0.1.2,10.0.1.3,10.0.1.4 \
  -v ds41-release:/var/lib/gr8/release -v ds41-home:/var/lib/gr8/home \
  ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest
docker logs -f ds41-4x-spark     # on the head: ready at "serving: http://..."
```

`<dir>/seccomp-iouring.json` is the profile that `install-seccomp.py` writes (see "The seccomp profile for io_uring"
below): clone this repo on each box and run the script once. Without that option, Docker's default profile blocks
io_uring and Engram reads its rows with a thread pool instead: the output is the same, and the numbers in "Results"
were measured with the profile.

With `mentat` running, replace the `PEERS`, `IPS` and `IPS2` settings with `-e MENTAT=1`. The head is then the box
with the lowest address. A container stops at once, and says why, if the release on its box is not whole. The boxes
wait for each other for 10 minutes, so start all four within that time. Expect about 2 minutes to ready.

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

After you update the image, run the fetch once more on every box: it checks every file and downloads only what is
wrong or missing. If the fetch names a file that does not match and stops, `fetch --force` deletes that file and
fetches it again.

## Run it with compose

`compose.yaml` runs the same image with the same settings and reads `PEERS` and the knobs from `.env`. It uses the
same `ds41-release` volume as the commands above. On every box:

```bash
git clone --recurse-submodules https://github.com/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark
cd deepseek-v4.1-flash-exlr8-4x-spark
cp .env.example .env          # uncomment and set PEERS, IPS and IPS2: the same file on every box
docker compose run --rm gr8 fetch
./install-seccomp.py
docker compose up -d
docker compose logs -f
```

Fetch first: compose restarts a container that stops with an error, so without the whole release it starts and stops
again until the fetch is done.

`docker compose up -d --build` builds the image on the box instead.

### The seccomp profile for io_uring

Docker's default seccomp profile blocks io_uring, which Engram uses to read its table from disk. `install-seccomp.py`
makes a profile that allows it, for this recipe's Compose service only.

`install-seccomp.py` needs Python 3, curl and access to Docker. It detects the Docker **server** version and fetches
that version's default profile from the official Moby `docker-v<version>` tag. It adds only `io_uring_setup`,
`io_uring_enter` and `io_uring_register`, writes `seccomp-iouring.json` next to `compose.yaml`, and updates only
`SECCOMP_PROFILE` in `.env`. The generated profile is not shipped in this repo or image. Run it on each box before
starting Compose and again after a Docker upgrade. It does not start or restart containers.

If the version lookup or fetch fails, it warns and selects Docker's `builtin` profile (not `unconfined`), so Compose
can still start without the generated profile. An io_uring-capable Engram build can then use its pread fallback.
An old generated file is not selected after a failed update. The override applies only to this recipe's service;
it does not alter Docker's daemon settings or other containers. For `docker run`, pass the file with
`--security-opt seccomp=...`, as the Quickstart shows.

## Web console

gr8 has a small web console ([gr8/tools/console](https://github.com/kindlingai/gr8/tree/{{GR8_SHA}}/tools/console)):
one page with the model's stats, the boxes, the head log, three presets, and a switch between models. It runs apart
from the engine, so it stays up while a model restarts, and it sends no requests to the model.

It is read-only until you set `allow_control` in its config. With control on, it can change the recipe's `.env` on
each box and restart the model: it keeps a backup of each file and has a "Restore previous settings" action. It has no
login: keep it on `localhost` and reach it through an SSH tunnel. Its
[README](https://github.com/kindlingai/gr8/blob/{{GR8_SHA}}/tools/console/README.md) has the setup.

## Knobs

Set these in `.env` next to `compose.yaml` (see `.env.example`), or with `docker run -e`, the same on every box:

| knob | default | |
|---|---|---|
| `PEERS` | none | The four boxes' 10G LAN addresses, head first. Required unless `MENTAT=1`. |
| `IPS`, `IPS2` | none | Each box's ConnectX address on PCIe root 1 and root 2, in `PEERS` order. |
| `SHAPE` | unset (a switch) | `ring`: four boxes cabled in a ring, without `IPS` and `IPS2`. |
| `TUNE` | `speed` | What to prioritize, see below. `EXACT=1`, the older name, is now `TUNE=quality`. |
| `CAP` | `327680`; `1048576` with `TUNE=context`; `262144` with `TUNE=quality` | The longest chat in tokens, prompt and reply together. Every chat slot gets this much KV at boot. A request holds at most `CAP` less 10 tokens (327,670 by default). |
| `SESS` | `32`; `16` with `TUNE=context`; `5` with `TUNE=quality` | Chats at once, 1 to 32. A chat that arrives when every slot is busy waits. |
| `MENTAT` | `0` | `1` finds the other boxes and the ConnectX addresses through the host's `mentat` daemon, and registers the API in group `GROUP` (`gr8-ds41-4x`). |
| `RELEASE` | a fixed commit | The release to fetch (`https://huggingface.co/<org>/<repo>@<commit>`). The fetch replaces only the files that differ. |
| `EXTRA_ENV` | none | Engine settings as `NAME=value` pairs separated by spaces (`EXTRA_ENV="A=1 B=2"`). They come after the recipe's own. |

[gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/4ed9e7bed53d6ed23ba1c4a32c993ccc3850af96/KNOBS.md) lists the
other `gr8` options, which you can also set in `.env`. Some engine settings for `EXTRA_ENV`:

- `GR8_DS_CACHE_MIB` sets the in-memory prefix cache on each box: 4,096 MiB by default, 2,048 with `TUNE=context`. A
  restart empties it.
- A setting you put in `EXTRA_ENV` replaces the recipe's value for it.

### What `TUNE=speed` sets

`TUNE=speed` turns on these engine settings, one line each. A setting from the list in `EXTRA_ENV` replaces it. The
rows marked "output" change the reply; the others give the same reply faster or with less memory.
[gr8/docs/ENV.md](https://github.com/kindlingai/gr8/blob/{{GR8_SHA}}/docs/ENV.md) has the full text of each.

| setting | what it does |
|---|---|
| `GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1` | output: accepts a drafted token by a relaxed rule (top-p 0.9, ratio 0.1), not only an exact match. |
| `GR8_DS_MOE_TOPK_DECODE=4` | output: a decode step takes 4 routed experts, fewer than prefill takes. |
| `GR8_DS41_HEAD_MX=1` | output: the decode output head in MXFP8, so it reads a little over half the bytes. |
| `GR8_DS_ATTN_TC_MF=2`, `GR8_DS_ATTN_TC_TILE=1` | the grid order and the tile of the tensor-core GEMM; the same output bits. |
| `GR8_DS_PF_V2=1` | the v2 prefill path for layers 0 to 20: each box keeps its own rows, with its own fabric and stream. |
| `GR8_DS_PF_LANES=1` | one prefill lane (v2 needs one). |
| `GR8_DS_PF_TAIL=128` | the late layers run only the last 128 rows of each prefill chunk (v2 needs 128). |
| `GR8_DS_PREFILL_W=8192` | prefill chunks of 8,192 rows. |
| `GR8_DS_SH_TC=1` | output: the shared expert of prefill runs on the tensor cores with MXFP8 input. |
| `GR8_DS_MHC_ROW_SHARD=0`, `GR8_DS_MHC_Y_MXFP8=0` | the mHC row split off. v2 with 8,192-row chunks needs it off; it applies to prefill only. |
| `GR8_DS_PF_V2_RS_BLOCKS=48` | v2 reduce-scatter with 48 blocks (gr8's default). |
| `GR8_DS_PF_V2_PACK_BLOCKS=48` | v2 wire pack and unpack with 48 blocks. |
| `GR8_DS_PF_V2_GATE_RO=1` | v2 expert gate reads its weights once per tile. |
| `GR8_DS_PF_V2_STRIPE_MIN=1048576` | v2 splits a message of 1 MiB or more across two fabric rails (`IPS` and `IPS2`). |
| `GR8_DS_PF_V2_ATTN_PIPE=1` | v2 attention loads the next block of keys while it works on the current one. |
| `GR8_DS_ENGRAM_IO_URING=128` | Engram reads its rows with io_uring (needs the seccomp profile). |
| `GR8_DS_ENGRAM_IO_THREADS=64` | Engram's thread pool when io_uring is off. |
| `GR8_DS_ENGRAM_COL_SHARD=1` | each box holds a quarter of Engram's columns (gr8's default). |

## Pick what to prioritize

`TUNE` picks one of three settings (`knobs.sh`). A `CAP` or `SESS` you set yourself keeps your value.

| `TUNE` | what you get |
|---|---|
| `speed` (default) | Fast mode, the settings in "Results": faster, but replies are not bit-identical to the exact model's. 32 chats at once, each up to 327,670 tokens. |
| `context` | Fast mode with one chat of up to 1,048,566 tokens, 16 chats at once. |
| `quality` | The exact model's output. 5 chats at once, each up to 262,134 tokens. |

## Switch between this and GLM-5.3 on the same four boxes

To run this recipe and [gr8's GLM-5.3](https://github.com/kindlingai/gr8/blob/main/docs/GLM-5.3.md) at TP=4 on the same
four boxes, one model at a time, two settings make the switch fast:

- `GR8_GEN_CACHE` in both models' `EXTRA_ENV` (`.env.example` turns it on for this recipe): the loader keeps the tensors
  it computes at load on the SSD and reads them back at the next boot with the same cache key: the same image, rank and
  release, and a `TUNE` of the same kind (`quality`, or `speed` and `context`). The first boot of a new key writes them.
- In gr8's `docker/.env` for GLM, `KV_STORE=ssd:<dir>,size=200G,persist=on,keep=sessions` with `GR8_STOP_GRACE=150s`:
  at the stop, GLM writes its open chats to the SSD, and the next boot reads them back.

### The gen cache: disk, first boot, off

- **Disk:** about 80 GB a box (79.6 GB), in the home volume (`GR8_HOME_DIR`), besides the 510.6 GB release. The loader
  keeps the entries of the two newest keys and deletes older ones, so a box that has used two keys holds up to about
  160 GB. A new image can make a new key.
- **First boot:** the first boot of a new key writes the cache and is slower. A new key comes from a new image, a change
  between `TUNE=quality` and `TUNE=speed` or `context`, a different rank (`PEERS` order), or a different release. Each
  one is a full 79.6 GB rewrite and a slow first boot.
  gr8's [SWITCHING.md](https://github.com/kindlingai/gr8/blob/main/docs/SWITCHING.md) measured 242 s from `up -d` to
  ready for DeepSeek's first start (2026-11-07, image `sha-50a8773`, four GB10 boxes in a ring, two of them not DGX
  Sparks; n not stated). gr8's [FIRST-BOOT.md](https://github.com/kindlingai/gr8/blob/main/docs/FIRST-BOOT.md)
  measured "engines ready" at 84 s without the cache, 110 s on the boot that writes it, and 16 s after (one boot each).
- **After the first boot:** a switch from GLM-5.3 into this recipe waited 35.9-36.8 s after `up -d` returned (two runs,
  the same boxes and image, cache written; SWITCHING.md).
- **Off:** put a `#` in front of the `EXTRA_ENV=GR8_GEN_CACHE=...` line in `.env` and run `docker compose up -d` on
  every box. The boot then computes the tensors every time. To free the disk, delete the `gen-cache` directory in the
  home volume.

GLM to DeepSeek, on every box (GLM from gr8's `docker/` directory, this recipe from its own):

```bash
(cd gr8/docker && docker compose down) && docker compose up -d
```

DeepSeek to GLM, on every box:

```bash
docker compose down && (cd gr8/docker && docker compose up -d)
```

## Run another model

A box runs one model at a time. To switch, stop and remove this recipe's container on every box:

```bash
docker stop ds41-4x-spark && docker rm ds41-4x-spark   # compose: docker compose down
```

The release stays in the `ds41-release` volume, so this recipe starts again later without a new fetch. To free its
510.6 GB and the gen cache, remove the volumes on every box:

```bash
docker volume rm ds41-release ds41-home
```

[gr8's Recipes](https://github.com/kindlingai/gr8#recipes) lists the other models and the number of boxes each one
needs.

## Help

Ask on Discord (https://discord.gg/8EAvYPV2rE) or open an issue in this repo
(https://github.com/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark/issues). Include the command you ran and the end of
`docker logs ds41-4x-spark`. [AGENTS.md](AGENTS.md#5-when-a-step-fails) lists the errors we know and what to do for
each. Remove addresses and hostnames before you post.
