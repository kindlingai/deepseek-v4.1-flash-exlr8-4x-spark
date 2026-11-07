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
- TCP ports 7340 and 7341 are open between the four boxes: no firewall blocks them. Check this before the boot, while
  nothing listens on those ports. `nc` may not be installed, so use `python3` and bash. On a peer, listen on one port:

  ```bash
  python3 -c 'import socket; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("", 7340)); s.listen(1); print("ACCEPTED from", s.accept()[1])'
  ```

  On the head, connect to it:

  ```bash
  timeout 5 bash -c 'exec 3<>/dev/tcp/<peer-address>/7340' && echo OPEN || echo BLOCKED
  ```

  The peer prints `ACCEPTED from` and the head's address, and the head prints `OPEN`. The listener stops after one
  connection, so start it again for each test. Do the same for port 7341, for each of the three peers, on the `PEERS`
  addresses and, if you set them, the `IPS` and `IPS2` addresses. Then test once the other way: listen on the head and
  connect from a peer.
  `BLOCKED` means a firewall, a wrong address, or no listener on the other box.
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
  - On a switch without `mentat`: each box has one ConnectX address per PCIe root. Addresses the ports already have
    are fine; README.md, Clustering, has a netplan file only for ports that have none.
    `ip -br addr show enp1s0f0np0` and `ip -br addr show enP2p1s0f0np0` show them, and `ls /dev/infiniband` lists
    devices. You need all four boxes' 10G LAN addresses (`PEERS`, head first), their root-1 ConnectX addresses (`IPS`)
    and their root-2 addresses (`IPS2`), each list in the same order.
  - In a ring without a switch: each box's f0 port is cabled to the next box's f1 port. Use `SHAPE=ring`, `PEERS` in
    that cable order, and no `IPS` or `IPS2`.

## 2. Pick the settings

Set the same values on all four boxes, in `.env` (compose) or with `docker run -e`.

`TUNE` picks what to prioritize. Ask the person, or use the default. We recommend `speed` or `context`. From README.md's
"Our view": the model tends to hallucinate a lot. That is a model issue, not an engine or quant issue.

| `TUNE` | the settings it sets (`knobs.sh`) | what it gives |
|---|---|---|
| `speed` (default) | `GR8_DS_RELAXED_ACCEPT=topp:0.9,ratio:0.1 GR8_DS_MOE_TOPK_DECODE=4 GR8_DS41_HEAD_MX=1 GR8_DS_ATTN_TC_MF=2 GR8_DS_ATTN_TC_TILE=1 GR8_DS_MHC_ROW_SHARD=1 GR8_DS_MHC_Y_MXFP8=1`, `SESS=32`, `CAP=327680` | fast mode: 32 chats of up to 327,670 tokens; replies not bit-identical to the exact model's |
| `context` | the first six of those switches (not `GR8_DS_MHC_Y_MXFP8`), `GR8_DS_CACHE_MIB=2048`, `SESS=16`, `CAP=1048576` | fast mode: one chat of up to 1,048,566 tokens, 16 chats at once |
| `quality` | none of those switches, `GR8_DS_MHC_Y_MXFP8` included (gr8's launcher defaults), `SESS=5`, `CAP=262144` | the exact model's output: 5 chats of up to 262,134 tokens |

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
| `FETCH_JOBS` | files the fetch, and the check before each boot, take at once | `8` |
| `HF_TOKEN` | sent only to Hugging Face, for a gated or private repo | none |
| `EXTRA_ENV` | more engine settings, `NAME=value` pairs separated by spaces | none |

Any other gr8 launcher option works too (gr8/KNOBS.md).

## 3. Boot

1. On every box, fetch the release: 604 files, 510.6 GB. It resumes if you run it again, checks every file's hash, and
   fetches a wrong file again. Wait until it has finished on all four boxes: the container refuses to start while the
   release on its box is not whole.

   ```bash
   docker run --rm --read-only -v ds41-release:/var/lib/gr8/release \
     ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest fetch
   ```

   The download is slow. In our run one box alone fetched the whole release in 74 minutes (4,420 s as the fetch
   reported it, 0.92 Gb/s on average). Four boxes at once got about 0.2 Gb/s each on the three boxes we logged (the
   fourth was not logged), which is about 5.7 hours (computed, not timed). So fetch on one box, then copy the whole
   `ds41-release` volume (the release and the `.fetch-*` record beside it) to the other three over the ConnectX ports.
   Check each copy before you run the fetch on that box: the copy (the README's Quickstart has the command) must print
   no `FAILED` line, and the volume must hold at least 510597801105 bytes:

   ```bash
   sudo du -sb "$(docker volume inspect ds41-release --format '{{ .Mountpoint }}')"
   ```

   A failed copy is easy to miss: in our run the first rsync exited 23 after 0 s and left each volume at about 10 GB.
   In our run the copy to all three at once took 260 s, about 1.9 GB/s to each box (each already held about 27 GB
   from an earlier try). Then run the fetch on each box that got the copy: it hashes every file and fetches only the
   wrong ones. That hash pass is timed only in the migration below: 60 s a box. A sparse copy (every file at its full
   size, only some bytes written) is not whole. Files copied without the record are refused.

   After you update the image, run the fetch once more on every box before you boot: it checks every file and
   downloads only what is wrong or missing.

   A release fetched with an image older than `sha-fe21314` (such as `sha-661d148`) has a record without hashes. The
   fetch, and the container at start, migrate it: only the file list is fetched, every file's blob id and size must
   match the record, then every file is hashed once, check only (60 s a box on four boxes at once, local NVMe). The
   migration deletes and downloads nothing. It names a file that does not match and stops: run the fetch with
   `fetch --force` on that box to fetch that file again.

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
  cluster serves. Expect about 2 minutes: in our run it printed this 104 s after the four containers started.
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
| `fetch-release.sh: no record that ... holds ..., with each file's hash (run the fetch)` | the volume holds another release: run the fetch (step 1). It hashes the files that are there and fetches only the wrong or missing ones |
| `ds41-4x: the fetch record beside ... is from an older image and was not migrated (above)` | the release was fetched with an image older than `sha-fe21314`, and the lines above name each file that differs from the release. Nothing was deleted. On that box, run the fetch (step 1) with `fetch --force` in place of `fetch`: it deletes those files and fetches them again |
| `fetch-release.sh: ... holds files but there is no record of their release ...: empty it first` | the volume holds files the fetch did not put there: copy the `.fetch-*` record beside the release with them (step 1), or empty the volume and fetch |
| `MISMATCH <file>: ...` | that file has its full size but not the content the release lists (a sparse or damaged copy): run the fetch (step 1), which fetches it again |
| `TUNE=...: want speed ..., context ... or quality ...` | use one of the three values |
| `EXACT=...: EXACT is now TUNE ...` | remove `EXACT`; set `TUNE=quality` for the exact model |
| `SESS=...: want a number of chats, 1 or more` | set `SESS` to a whole number from 1 to 32, no leading zero |
| `gr8: memlock is limited ...` | `--ulimit memlock=-1` with `docker run`, `ulimits.memlock: -1` in compose |
| `gr8: ... is not writable by uid 1000 ...` | `chown 1000:1000` the `GR8_HOME_DIR` directory |
| the image does not pull | build it on the box from a clone with its submodule: `docker compose build` in the clone (it tags the image `ghcr.io/kindlingai/deepseek-v4.1-flash-exlr8-4x-spark:latest`), or `docker buildx build --platform linux/arm64 -t ds41-4x-spark .` and use that tag |
| a box never joins | start all four within 600 s; check that `PEERS` and every other knob are the same on every box, head first, and that ports 7340 and 7341 are open |

The container's exit status is the launcher's: 0 after a stop, 1 when a rank failed, 2 for bad options, 4 when the
boxes' handshake refused the boot. `docker inspect -f '{{.State.ExitCode}}' ds41-4x-spark` prints it. The logs are
in the home volume: `out/supervisor.log`, `g6m4.r0.err`, `shim.log`, `front.log`.

On the box that failed, read its log:

- After the container exits: `docker logs ds41-4x-spark` (compose: `docker compose logs`). It has the launcher's
  output, and it is there until you remove the container.
- While the container runs: `docker exec ds41-4x-spark gr8 ds41 logs supervisor` (or `shim`, `front`, or no word for
  the engine).

If a step fails for a reason not listed here, ask on the KindlingAI Discord (the link is at the top of README.md).

## 6. Not measured yet: tell the person

- We booted the image `sha-661d148` on four boxes on 2026-11-06: ready in 104 s, smoke test 11 of 11, 72 of 75 right
  on the 75-item check in fast mode. The speed numbers in README.md still come from an older gr8 with the same engine
  settings, booted through our own test harness. The KV cache is always fp8, and the image's engine is built with
  `DS41_MX=48`.
- `TUNE=context` was measured on the image `sha-15b7eec` in one boot on 2026-11-07 (README.md, More numbers,
  `TUNE=context`): a cold 1,031,542-token prompt read in 388.7 s (2,650 tok/s), the same prompt again in 1.19 s from
  the prefix cache, replies after it at 91.9 tok/s, and 8.7-9.4 GiB free a box just after ready. Recall and output
  quality at 1M, and three distinct cold 1M prompts at once, are not measured on that image.
- Before that, gr8/docs/FIRST-BOOT.md Q2 ran `TUNE=context` on an earlier gr8 build, with 16 slots of 1M each, at most
  three 1M chats at once, and only two of the six switches. On that build:
  - a 1,031,542-token prompt took about 417 s to read;
  - recall at 1M found all 3 hidden facts in only 2 of 7 prompts;
  - at 2,048 MiB of prefix cache, only the last 1M chat stayed cached;
  - free memory was 3.2-3.4 GiB a box after one full 1M chat, and at least 2.69 GiB while three ran at once. More
    than three at once was not tested.
- `TUNE=quality` has not been measured on this image's `DS41_MX=48` build. Its numbers are from older builds.
