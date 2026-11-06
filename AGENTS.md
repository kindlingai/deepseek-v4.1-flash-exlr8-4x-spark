# For agents: boot DeepSeek-V4.1-Flash on four DGX Sparks

You are booting this recipe for someone. This file has the steps, every knob, and how to check each step. It is taken
from README.md, `knobs.sh`, `.env.example`, `compose.yaml`, the `Dockerfile` and gr8 (the `gr8/` submodule). If this
file and `knobs.sh` or `compose.yaml` disagree, follow `knobs.sh` and `compose.yaml`, and tell the person. If you
cannot run a check yourself, ask the person.

## 1. Check the four boxes

On every box:

- It is a DGX Spark (GB10, 128 GB). All four are on one 200G switch, or cabled in a ring (README.md, Clustering).
- Docker and the NVIDIA container toolkit are installed (both come with DGX OS): `docker info | grep -i nvidia` shows
  the `nvidia` runtime.
- 510.6 GB of disk is free where Docker keeps volumes, for the release volume `ds41-release`:
  `df -h "$(docker info --format '{{.DockerRootDir}}')"`. Or set `RELEASE_DIR` to a host directory on local NVMe,
  owned by uid 1000.
- The box can reach Hugging Face for the fetch: `curl -sI https://huggingface.co` answers.
- TCP ports 7340 and 7341 are open between the four boxes: no firewall blocks them.
- No other model runs on the box: `docker ps` and `nvidia-smi` show none. The launcher refuses to start next to
  another g6m4 engine on the box.
- Proactive memory compaction is off: `sysctl vm.compaction_proactiveness` prints 0. If not, as root, once:

  ```bash
  echo 'vm.compaction_proactiveness = 0' > /etc/sysctl.d/90-gr8-no-proactive-compaction.conf
  sysctl -w vm.compaction_proactiveness=0
  ```

- The fabric, one of:
  - With `mentat` (README.md, Clustering) running on every box: `docker ps` shows the `mentat` container. Use
    `MENTAT=1` below and leave out `PEERS`, `IPS` and `IPS2`.
  - On a switch without `mentat`: each box has one ConnectX address per PCIe root (README.md, Clustering, has the
    netplan file). `ip -br addr show enp1s0f0np0` and `ip -br addr show enP2p1s0f0np0` show them, and
    `ls /dev/infiniband` lists devices. You need all four boxes' 10G LAN addresses (`PEERS`, head first), their root-1
    ConnectX addresses (`IPS`) and their root-2 addresses (`IPS2`), each list in the same order.
  - In a ring without a switch: each box's f0 port is cabled to the next box's f1 port. Use `SHAPE=ring`, `PEERS` in
    that cable order, and no `IPS` or `IPS2`.

## 2. Pick the settings

Set the same values on all four boxes, in `.env` (compose) or with `docker run -e`.

`TUNE` picks what to prioritize. Ask the person, or use the default. We recommend `speed` or `context`. From README.md's
"Our view": the model tends to hallucinate a lot. That is a model issue, not an engine or quant issue.

| `TUNE` | the settings it sets (`knobs.sh`) | what it gives |
|---|---|---|
| `speed` (default) | `GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4 GR8_DS41_HEAD_MX=1 GR8_DS_ATTN_TC_MF=2 GR8_DS_ATTN_TC_TILE=1 GR8_DS_MHC_ROW_SHARD=1`, `SESS=32`, `CAP=327680` | fast mode: 32 chats of up to 327,670 tokens; replies not bit-identical to the exact model's |
| `context` | the same six switches, `GR8_DS_CACHE_MIB=2048`, `SESS=16`, `CAP=1048576` | fast mode: one chat of up to 1,048,566 tokens, 16 chats at once |
| `quality` | none of the six switches (gr8's launcher defaults), `SESS=5`, `CAP=262144` | the exact model's output: 5 chats of up to 262,134 tokens |

What else `knobs.sh` does:

- Every value also sets Engram (`GR8_DS_ENGRAM=1`, `GR8_DS_ENGRAM_PREFIX`).
- Every value adds `GR8_DS_SESS_DRAFTS=1` when `SESS` is above 5.
- A `CAP` or `SESS` you set is kept.
- Settings in `EXTRA_ENV` come after the recipe's, so yours win.
- Any other `TUNE` value stops the boot. `EXACT` is the older name: the image refuses it and says that `EXACT=1` is
  `TUNE=quality`.

Every knob:

| knob | values | default |
|---|---|---|
| `PEERS` | the four boxes' 10G LAN addresses, comma-separated, head first, the same list on every box | none: required unless `MENTAT=1` |
| `IPS`, `IPS2` | each box's ConnectX address on PCIe root 1 and root 2, in `PEERS` order | none |
| `SHAPE` | `ring`: four boxes cabled in a ring, without `IPS` and `IPS2` | unset (a switch) |
| `TUNE` | `speed`, `context`, `quality` | `speed` |
| `CAP` | the longest chat in tokens, prompt and reply; every slot gets this much KV at boot; a request holds `CAP` less 10 | by `TUNE` (table above) |
| `SESS` | chats at once: a whole number from 1 to 32, no leading zero | by `TUNE` (table above) |
| `MENTAT` | `0`: the boxes in `PEERS`. `1`: find the boxes through the host's `mentat` daemon and register the API | `0` |
| `GROUP` | the `mentat` group | `gr8-ds41-4x` |
| `RELEASE_DIR`, `GR8_HOME_DIR` | compose only: host directories in place of the volumes `ds41-release` and `ds41-home`, owned by uid 1000 | the named volumes |
| `IMAGE` | compose only: a pinned image, e.g. `ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:sha-<commit>` | `:latest` |
| `RELEASE` | the release to fetch, `https://huggingface.co/<org>/<repo>@<commit>` | the commit README.md measured |
| `FETCH_JOBS` | files the fetch takes at once | `8` |
| `HF_TOKEN` | sent only to Hugging Face, for a gated or private repo | none |
| `EXTRA_ENV` | more engine settings, `NAME=value` pairs separated by spaces | none |

Any other gr8 launcher option works too (gr8/KNOBS.md).

## 3. Boot

1. On every box, fetch the release: 604 files, 510.6 GB. It resumes if you run it again. Wait until it has finished
   on all four boxes: the container refuses to start while the release on its box is not whole.

   ```bash
   docker run --rm --read-only -v ds41-release:/var/lib/gr8/release \
     ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest fetch
   ```

2. Optional, on every box: print the settings the boot will use, and compare the `CAP`, `SESS` and `EXTRA_ENV` lines
   with the `TUNE` table above. The output goes to stdout. With `mentat`, pass `-e MENTAT=1` in place of `PEERS`.

   ```bash
   docker run --rm -e PEERS=<head>,<box2>,<box3>,<box4> -e TUNE=speed \
     ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest show-config --no-check
   ```

3. Start the container on all four boxes within 10 minutes of each other: the boxes wait for each other for 600 s
   (gr8's `JOIN_TIMEOUT`). Replace each `<...>` with the real values, the same on every box:

   ```bash
   docker run -d --name ds41-4x-spark --gpus all --network host --pid host --device /dev/infiniband \
     --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
     --security-opt no-new-privileges --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
     -e PEERS=<head>,<box2>,<box3>,<box4> -e IPS=<four root-1 addresses> -e IPS2=<four root-2 addresses> \
     -e TUNE=speed \
     -v ds41-release:/var/lib/gr8/release -v ds41-home:/var/lib/gr8/home \
     ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest
   ```

   With `mentat`, replace the `PEERS`, `IPS` and `IPS2` line with `-e MENTAT=1`. In a ring, replace it with
   `-e PEERS=<the four, in cable order> -e SHAPE=ring`.

   Or with compose, on every box:

   ```bash
   git clone --recurse-submodules https://github.com/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark
   cd deepseek-v4.1-flash-exlr8-4x-spark
   cp .env.example .env          # set PEERS, IPS and IPS2 (or MENTAT=1), and TUNE: the same file on every box
   docker compose run --rm gr8 fetch
   docker compose up -d
   ```

4. To change `TUNE` or any other knob later: stop and remove the container on all four boxes, then start it again with
   the new value on all four. The boxes refuse to join unless they all have the same options.

## 4. Check that it serves

- On the head, `docker logs -f ds41-4x-spark` (compose: `docker compose logs -f`) prints `serving: http://...` when the
  cluster serves.
- On every box, `docker exec ds41-4x-spark gr8 ds41 health` exits 0 when that box serves. With compose,
  `docker compose ps` shows the container as `healthy` once this check passes.
- `docker exec ds41-4x-spark gr8 ds41 status` shows every box's state, engine and free memory.
- On the head, `docker exec ds41-4x-spark gr8 ds41 smoke` checks the API, tool calls included. It exits 0 when every
  case passes.
- The API is OpenAI-compatible, on the head's port 8100, with the model name `deepseek-v4.1-flash`. Send one chat:

  ```bash
  curl -s localhost:8100/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "model": "deepseek-v4.1-flash",
    "messages": [{"role": "user", "content": "Write a haiku about a small computer."}],
    "max_tokens": 4096
  }'
  ```

  The reply is JSON with a `choices` list. A request that does not set a reasoning effort runs at effort `low`.
- To stop, on every box: `docker stop ds41-4x-spark && docker rm ds41-4x-spark` (compose: `docker compose down`).

## 5. When a step fails

| what you see | what to do |
|---|---|
| `PEERS=...: want the four boxes' LAN addresses, head first, the same on every box (or MENTAT=1)` | set `PEERS` to four addresses, the same list on every box, or `MENTAT=1` |
| `ds41-4x: the release in ... is not whole: run the fetch first, on every box` | run the fetch (step 1) on that box. With compose, the container restarts and stops again until the fetch is done |
| `TUNE=...: want speed ..., context ... or quality ...` | use one of the three values |
| `EXACT=...: EXACT is now TUNE ...` | remove `EXACT`; set `TUNE=quality` for the exact model |
| `SESS=...: want a number of chats, 1 or more` | set `SESS` to a whole number from 1 to 32, no leading zero |
| `gr8: memlock is limited ...` | `--ulimit memlock=-1` with `docker run`, `ulimits.memlock: -1` in compose |
| `gr8: ... is not writable by uid 1000 ...` | `chown 1000:1000` the `GR8_HOME_DIR` directory |
| the image does not pull | build it on the box from a clone with its submodule: `docker compose build` in the clone (it tags the image `ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest`), or `docker buildx build --platform linux/arm64 -t ds41-4x-spark .` and use that tag |
| a box never joins | start all four within 600 s; check that `PEERS` and every other knob are the same on every box, head first, and that ports 7340 and 7341 are open |

The container's exit status is the launcher's: 0 after a stop, 1 when a rank failed, 2 for bad options, 4 when the
boxes' handshake refused the boot. The logs are in the home volume: `out/supervisor.log`, `g6m4.r0.err`, `shim.log`,
`front.log`. Read one with `docker exec ds41-4x-spark gr8 ds41 logs supervisor` (or `shim`, `front`, or no word for
the engine). If a step fails for a reason not listed here, ask on the KindlingAI Discord (the link is at the top of
README.md).

## 6. Not measured yet: tell the person

- We have not yet booted the image on four boxes. The numbers in README.md come from an older gr8 with the same engine
  settings, booted through our own test harness. The KV cache is always fp8, and the image's engine is built with
  `DS41_MX=48`.
- `TUNE=context` is only partly measured. gr8/docs/FIRST-BOOT.md Q2 ran it on an earlier gr8 build, with 16 slots of
  1M each, at most three 1M chats at once, and only two of the six switches. Speed at 1M is not measured. On that
  build:
  - a 1,031,542-token prompt took about 417 s to read;
  - recall at 1M found all 3 hidden facts in only 2 of 7 prompts;
  - at 2,048 MiB of prefix cache, only the last 1M chat stayed cached;
  - free memory was 3.2-3.4 GiB a box after one full 1M chat, and at least 2.69 GiB while three ran at once. More
    than three at once was not tested.
- `TUNE=quality` has not been measured on this image's `DS41_MX=48` build. Its numbers are from older builds.
