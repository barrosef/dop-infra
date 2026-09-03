#!/bin/sh
# The sandbox's entrypoint: bring the shelf up, then hand over.
#
# The shelf is the project's root repository (ADR-0028), cloned at
# DOP_PROJECT_DIR before anything else runs — from the agent's point of view it
# was always there. The credential is a FILE, never an environment variable:
# environ is inherited by every child process, and children here are agent
# code. Git reads the file through a credential helper, so the token never
# appears in a URL, in `ps`, or in the shell's history.
#
# With no DOP_PROJECT_REPO there is no shelf and nothing to do — the contract
# suite's lifecycle tests raise the image exactly like that.
set -eu

: "${DOP_PROJECT_DIR:=/project}"
: "${DOP_GIT_TOKEN_FILE:=/etc/dop/git-token}"

if [ -n "${DOP_PROJECT_REPO:-}" ]; then
  if [ ! -r "$DOP_GIT_TOKEN_FILE" ]; then
    echo "[infra] DOP_PROJECT_REPO is set but the token file is not readable: $DOP_GIT_TOKEN_FILE" >&2
    exit 64
  fi
  # The credential helper and safe.directory live in /etc/gitconfig, written at
  # build time — see the Dockerfile. They have to be there and not here: an exec
  # into this sandbox does not inherit anything this script exports.
  export GIT_TERMINAL_PROMPT=0

  if [ -d "$DOP_PROJECT_DIR/.git" ]; then
    # A resume: the shelf is there, the project may have moved on.
    echo "[infra] refreshing the shelf at $DOP_PROJECT_DIR"
    git -C "$DOP_PROJECT_DIR" pull -q --ff-only origin main || \
      echo "[infra] the shelf could not be refreshed; working with what is there" >&2
  else
    echo "[infra] cloning the shelf into $DOP_PROJECT_DIR"
    git clone -q "$DOP_PROJECT_REPO" "$DOP_PROJECT_DIR"
  fi
  # Whoever commits from inside identifies as the thread (ADR-0003): the runtime
  # sets author and committer per commit. This is the fallback, in the
  # repository's own config, so a commit made by hand is not anonymous.
  git -C "$DOP_PROJECT_DIR" config user.name "${DOP_THREAD_ID:-sandbox}"
  git -C "$DOP_PROJECT_DIR" config user.email "${DOP_THREAD_ID:-sandbox}@agents.dop"
fi

exec "$@"
