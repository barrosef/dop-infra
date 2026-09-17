# The image a VERIFICATION runs in (ADR-0023).
#
# It is the opposite animal from the devbox. The devbox stays up waiting for the
# agent's commands; this one runs ONE script — clone, build, start, check — and
# exits. Its log is the run's record, which is why nothing here writes to stdout
# that is not the run's own output.
#
# ── Why this image is FAT, on purpose ───────────────────────────────────────
#
# The decision it implements is "build the application from source, never from
# an image of it": the slow sequence was never the build, it was
# `build → push → pull` around a registry that exists only to move bytes between
# two places in one cluster. Cutting that leaves `pull the code → build → start`
# — which is what every CI runner in the world does, and what a developer does
# on their own machine.
#
# For that to be fast, the TOOLCHAINS have to be here already, cached on the
# nodes. One big image every node has beats a small image built per demand. The
# cost is stated in the ADR and accepted: this image has to carry the versions
# customers use, and version drift is maintenance we take on instead of pushing
# it onto the client.
#
# ── The three tools the run script calls BY NAME ────────────────────────────
#
# `sh`, `git` and `nc`. The script's first act is to check for them and refuse
# with a message naming what is missing — because "git: not found" three steps
# later, buried inside a build's log, costs somebody an afternoon.
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

# The base: what the script itself needs, plus what a build script assumes
# exists. `netcat-openbsd` is the `nc` the readiness wait uses.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git netcat-openbsd \
      build-essential pkg-config unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# ── the toolchains ──────────────────────────────────────────────────────────
#
# Pinned, every one of them. A runner that follows "latest" changes what it
# proves without anybody deciding to change it — and the day a build breaks,
# nobody can tell whether the code or the image moved.

ARG GO_VERSION=1.27.0
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:/root/.local/bin:$PATH \
    GOPATH=/go \
    GOCACHE=/cache/go-build \
    GOMODCACHE=/cache/go-mod

ARG NODE_VERSION=22.11.0
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -C /usr/local --strip-components=1 -xJ \
 && corepack enable
ENV npm_config_cache=/cache/npm

RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && curl -LsSf https://astral.sh/uv/install.sh | sh
ENV UV_CACHE_DIR=/cache/uv PIP_CACHE_DIR=/cache/pip

# The cache paths above all live under /cache, which is where the ACCOUNT's
# volume is mounted. The directory exists so a run with NO declared cache still
# writes somewhere valid instead of failing on a missing path.
RUN mkdir -p /cache /work

# Root, and deliberately so — unlike the devbox, which OKD's SCC forces to an
# arbitrary uid. A build legitimately installs packages, writes to system paths
# and runs whatever the project's own script asks for. The isolation is the
# runner's ephemerality and its network policy, not a uid: this container exists
# for one commit and is destroyed.
WORKDIR /work

# No ENTRYPOINT and no CMD: the adapter replaces the command with the run
# script, and an entrypoint here would only be something to remember to bypass.
