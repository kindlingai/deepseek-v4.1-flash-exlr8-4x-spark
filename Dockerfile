# DeepSeek-V4.1-Flash on four GB10 boxes: gr8 (the gr8/ submodule) with only the engine this recipe runs, g6m4_ds41 at
# TP=4, plus the front end, the loader, the launcher and Engram's token map. linux/arm64, CUDA 13, sm_121a. All four
# boxes run this image.
#
#   docker buildx build --platform linux/arm64 -t ds41-4x-spark .      (compose.yaml builds it the same way)
#
# The stages are gr8's own Dockerfile cut down to one engine: gr8's builds every engine for every TP width, which takes
# far longer. Keep the two in step when the submodule moves (toolchain, Rust pin, runtime packages).
ARG CUDA_VERSION=13.0.1
ARG UBUNTU=ubuntu24.04

FROM nvidia/cuda:${CUDA_VERSION}-devel-${UBUNTU} AS toolchain
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ binutils libibverbs-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

FROM toolchain AS rust
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# gr8/frontend/g6front-rs/rust-toolchain.toml pins the compiler: keep RUST_VERSION equal to it
ARG RUST_VERSION=1.94.1
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
WORKDIR /src

FROM rust AS libs
COPY gr8/engine/knobs-rs engine/knobs-rs
COPY gr8/knobs knobs
COPY gr8/engine/loader-rs engine/loader-rs
COPY gr8/engine/Cargo.toml gr8/engine/Cargo.lock engine/
COPY gr8/engine/hostcore-rs engine/hostcore-rs
COPY gr8/engine/kvman-rs engine/kvman-rs
COPY gr8/engine/scheduler-rs engine/scheduler-rs
RUN mkdir -p /out \
 && cargo build --release --locked --manifest-path engine/loader-rs/Cargo.toml \
 && cargo build --release --locked --manifest-path engine/Cargo.toml \
 && cargo build --release --locked --features capi --manifest-path engine/knobs-rs/Cargo.toml \
 && cargo rustc --release --locked --features capi --lib --crate-type cdylib --manifest-path engine/knobs-rs/Cargo.toml \
 && cp engine/loader-rs/target/release/libg6load.a engine/loader-rs/target/release/g6load \
       engine/target/release/libg6host.a engine/target/release/kvman-remote \
       engine/knobs-rs/target/release/libgr8knobs.a engine/knobs-rs/target/release/libgr8knobs.so /out/ \
 && rm -rf engine/target engine/*/target

FROM rust AS front
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake clang libclang-dev \
 && rm -rf /var/lib/apt/lists/*
COPY gr8/engine/knobs-rs engine/knobs-rs
COPY gr8/knobs knobs
COPY gr8/frontend/g6front-rs frontend/g6front-rs
WORKDIR /src/frontend/g6front-rs
RUN mkdir -p /out \
 && cargo build --release --locked \
 && cp target/release/g6front-rs /out/ \
 && rm -rf target

# g6m4_ds41: DeepSeek-V4.1-Flash-1017, fp8 KV, TP=4 only. build.sh builds it without request grammars, so this stage
# needs no XGrammar. Its build knobs come from scripts/ds41_build_flags.sh. DS41_MX=48 (engine/runtime/build_m4.sh,
# opt-in in gr8): 48 rows a step instead of 32, the build fast mode was measured on (README.md, More numbers).
FROM toolchain AS engine
WORKDIR /src
COPY gr8/engine engine
COPY gr8/tools/health/gpuprobe.cu tools/health/gpuprobe.cu
COPY gr8/scripts/build.sh gr8/scripts/ds41_build_flags.sh scripts/
COPY --from=libs /out/libg6load.a engine/loader-rs/target/release/libg6load.a
COPY --from=libs /out/libg6host.a engine/target/release/libg6host.a
COPY --from=libs /out/libgr8knobs.a engine/knobs-rs/target/release/libgr8knobs.a
RUN DS41_MX=48 MODEL=ds41 scripts/build.sh /out/bin \
 && find /out/bin -mindepth 1 -maxdepth 1 ! -name g6m4_ds41 -exec rm -rf {} +

# Engram's token map (gr8/docs/DEEPSEEK-BOOT.md, "Engram: the token map you write once"), written here so no box has to:
# gr8's generator reads two files of the official DeepSeek repo and the release's tokenizer, and the build stops unless
# the map's sha256 equals the one the engine checks at boot (kCmapSha256 in gr8/engine/engram/hash_consts.h).
FROM ubuntu:24.04 AS engram
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
# CPU torch: the generator runs the reference's hashing on a few hundred tokens
# hadolint ignore=DL3013
RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch \
 && /venv/bin/pip install --no-cache-dir tokenizers numpy
ARG REFERENCE=deepseek-ai/DeepSeek-V4.1-Flash-1017@1bae0e1088993b9b82de08f59de5be5a34e42170
ARG RELEASE=kindlingai/deepseek-v4.1-flash-exlr8-native@98076325aaa2c8dfec6095536d69c47bfcfbb3dc
COPY gr8/engine/engram/gen_engram.py gr8/engine/engram/hash_consts.h /gen/
RUN mkdir -p /ref/inference /out \
 && for f in inference/config.json inference/engram.py; do \
      curl -fsSL -o "/ref/$f" "https://huggingface.co/${REFERENCE%@*}/resolve/${REFERENCE#*@}/$f"; done \
 && curl -fsSL -o /ref/tokenizer.json "https://huggingface.co/${RELEASE%@*}/resolve/${RELEASE#*@}/tokenizer.json" \
 && /venv/bin/python /gen/gen_engram.py --ref /ref --tok /ref/tokenizer.json --out-h /tmp/hash_consts.h \
      --out-cmap /out/ds41.engram.cmap \
 && want=$(grep -o 'kCmapSha256 = "[0-9a-f]*"' /gen/hash_consts.h | cut -d'"' -f2) \
 && got=$(sha256sum /out/ds41.engram.cmap | cut -d' ' -f1) \
 && { [ -n "$want" ] && [ "$got" = "$want" ] || { echo "token map sha256 $got, the engine wants $want"; exit 1; }; }

FROM nvidia/cuda:${CUDA_VERSION}-runtime-${UBUNTU} AS runtime
# python3 for the launcher and the shim, curl + jq for the smoke test and the release fetch. libibverbs1 and
# ibverbs-providers (libmlx5) for the ConnectX fabric between the boxes.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libibverbs1 ibverbs-providers python3 python3-yaml curl jq \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/gr8
COPY gr8/ .
COPY --from=engine /out/bin/g6m4_ds41 bin/
COPY --from=libs /out/g6load /out/kvman-remote bin/
COPY --from=libs /out/libgr8knobs.so bin/lib/
COPY --from=front /out/g6front-rs bin/
COPY --from=engram /out/ds41.engram.cmap /opt/ds41-4x/ds41.engram.cmap
COPY entrypoint.sh knobs.sh fetch-release.sh /opt/ds41-4x/
COPY bin/gr8 /opt/ds41-4x/bin/gr8
# The container runs as uid 1000 on a read-only image. Its writable state is two volumes (compose.yaml): the release and
# GR8_WORK_DIR, which docker fills from these empty, uid-1000 directories on first use.
RUN mkdir -p /var/lib/gr8/home /var/lib/gr8/release \
 && chown 1000:1000 /var/lib/gr8/home /var/lib/gr8/release
ENV PATH=/opt/ds41-4x/bin:/opt/gr8/bin:$PATH PYTHONPATH=/opt/gr8/frontend HOME=/tmp GR8_CONTAINER=1 GR8_MODEL=ds41 \
    GR8_WORK_DIR=/var/lib/gr8/home PY=/usr/bin/python3 FRONT_BIN=/opt/gr8/bin/g6front-rs
# The recipe's knobs (README.md, "Knobs"). Set any of them in .env, or with docker run -e, to override.
#   TUNE    speed: fast mode, not exact (32 chats, CAP 327680); context: fast mode, one chat up to 1M tokens (16 chats,
#           CAP 1048576); quality: the exact model (5 chats, CAP 262144) (knobs.sh)
#   CAP     the longest chat in tokens, prompt and reply together; every chat slot gets this much KV at boot.
#           Unset: by TUNE (knobs.sh)
#   SESS    chats at once; above 5, knobs.sh adds GR8_DS_SESS_DRAFTS=1: each chat drafts fewer tokens as more chats
#           write, and none when more than 24 write. Unset: by TUNE
#   MENTAT  0: the four boxes in PEERS; 1: find each other through mentat (knobs.sh)
ENV TUNE=speed MENTAT=0
# The rest of the recipe, as gr8's launcher options (gr8/KNOBS.md)
#   MODEL:   the release, read in place from the release volume (fetch-release.sh puts it there)
#   RELEASE: the Hugging Face commit fetch-release.sh fetches, the one measured in README.md
#   ENGRAM_PREFIX: where entrypoint.sh puts the token map; the loader writes its own Engram index beside it each boot
# PEERS (and IPS, IPS2) have no default: they name the four boxes (knobs.sh, .env.example).
ENV TP=4 GROUP=gr8-ds41-4x MODEL=/var/lib/gr8/release/deepseek-v4.1-flash-exlr8-native \
    RELEASE=https://huggingface.co/kindlingai/deepseek-v4.1-flash-exlr8-native@98076325aaa2c8dfec6095536d69c47bfcfbb3dc \
    ENGRAM_PREFIX=/var/lib/gr8/home/engram/ds41
USER 1000:1000
ENTRYPOINT ["/opt/ds41-4x/entrypoint.sh"]
