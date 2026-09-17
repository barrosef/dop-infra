#!/bin/sh
# The sandbox's entrypoint: bring the shelf up, then hand over.
#
# The shelf is the project's root repository (ADR-0021), cloned at
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

# ── the agent's own answer about how it authenticated ───────────────────────
#
# The measurement has to be about what ACTUALLY happened, and only the tool
# knows: a stray ANTHROPIC_API_KEY makes it bill a key instead of the
# subscription, and a collector that guessed from the environment would measure
# the wrong thing with nothing saying so.
#
# So the tool is ASKED, once, here — this is the only container that has the
# binary — and the answer is left where the collector reads it.
#
# Note what is NOT done: the variable is not unset. Unsetting would break the
# BYOK path, where billing a key is the correct behaviour. What is wanted is not
# one method over the other; it is knowing WHICH one, always.
if [ -n "${DOP_SESSION_DIR:-}" ] && [ -d "${DOP_SESSION_DIR:-}" ]; then
  if command -v claude >/dev/null 2>&1; then
    # Only the fields about the METHOD are kept. The e-mail and the organization
    # are dropped on the way out: the platform already knows whose demand this
    # is, and a second identity would add a surface without adding a measurement.
    claude auth status 2>/dev/null \
      | sed -n 's/.*"\(authMethod\|apiProvider\|subscriptionType\|apiKeySource\)": *\("[^"]*"\|null\).*/  "\1": \2,/p' \
      | sed '$ s/,$//' \
      | { echo "{"; cat; echo "}"; } > "$DOP_SESSION_DIR/.auth.json" 2>/dev/null \
      || echo "[infra] could not read the tool's auth state" >&2
  else
    echo "[infra] claude is not in this image; the auth state will be unknown" >&2
  fi
fi

exec "$@"
