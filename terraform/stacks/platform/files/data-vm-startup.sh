#!/bin/bash
# The QA data VM: Postgres, NATS and the core's worker, on one Always Free e2-micro.
#
# Why these three together on one machine: they are the parts that must be
# LISTENING, and Cloud Run bills for an instance that never sleeps. Everything
# request-driven — the core's `serve`, the BFF — lives on Cloud Run and scales to
# zero. This VM is the exception that pays for itself by being free.
#
# It is a QA machine. There is no backup, no failover and no SLA, and the three
# processes share 1 GB. That is written down rather than discovered.
set -euo pipefail
exec > >(logger -t dop-startup) 2>&1

REGION=${region}
PROJECT=${project}
AR="$${REGION}-docker.pkg.dev/$${PROJECT}/dop"
CORE_TAG=${core_image_tag}

token() {
  curl -s -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# The password never appears in this file, in the instance metadata, or in an
# image. It is read at boot from Secret Manager with the VM's own identity.
PGPASS=$(curl -s -H "Authorization: Bearer $(token)" \
  "https://secretmanager.googleapis.com/v1/projects/$${PROJECT}/secrets/dop-postgres-password/versions/latest:access" \
  | sed -n 's/.*"data": "\([^"]*\)".*/\1/p' | base64 -d)

# /root is read-only on Container-Optimized OS, and docker-credential-gcr writes
# its config under $HOME. Point HOME somewhere writable before calling it.
export HOME=/var/lib/dop
mkdir -p "$${HOME}"
docker-credential-gcr configure-docker --registries="$${REGION}-docker.pkg.dev"

# ── The host firewall ───────────────────────────────────────────────────────
# Container-Optimized OS ships with INPUT set to DROP. A VPC firewall rule that
# allows 5432 is necessary and NOT sufficient: the packet arrives and the
# operating system discards it, with nothing in the GCP console to suggest why.
# Cloud Run reports a dial timeout, which reads like a routing problem.
#
# Scoped to the private range, never 0.0.0.0/0 — this machine has no external
# address and nothing outside the VPC has business talking to the database.
for port in 5432 4222; do
  iptables -C INPUT -p tcp -s 10.128.0.0/9 --dport "$port" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp -s 10.128.0.0/9 --dport "$port" -j ACCEPT
done

mkdir -p /var/lib/dop/pgdata /var/lib/dop/nats /var/lib/dop/git
chmod 777 /var/lib/dop/git

# ── Postgres ────────────────────────────────────────────────────────────────
# pgvector, not plain postgres: 0001_foundation.sql requires the `vector`
# extension and plain postgres:16 fails on it — a trap this project has hit.
#
# It is pulled from OUR registry, not Docker Hub. This VM has no route to the
# internet — only Private Google Access, which reaches Google APIs and nothing
# else. Mirroring the third-party images is not paranoia here, it is the only
# way they arrive.
#
# shared_buffers is pinned low on purpose. Postgres sizes itself for the machine
# it finds, and on a 1 GB box shared with NATS and a Go worker, its defaults are
# the thing that starts the OOM killer.
docker rm -f postgres 2>/dev/null || true
docker run -d --name postgres --restart=always --network=host \
  -e POSTGRES_USER=dop -e POSTGRES_PASSWORD="$${PGPASS}" -e POSTGRES_DB=dop \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v /var/lib/dop/pgdata:/var/lib/postgresql/data \
  --memory=420m \
  "$${AR}/pgvector:pg16" \
  -c shared_buffers=96MB -c max_connections=50 -c work_mem=2MB

# ── NATS with JetStream ─────────────────────────────────────────────────────
# The core refuses to boot without it (internal/app/wire.go), so this is not
# optional even for a environment that consumes no events yet.
docker rm -f nats 2>/dev/null || true
docker run -d --name nats --restart=always --network=host \
  -v /var/lib/dop/nats:/data --memory=96m \
  "$${AR}/nats:2-alpine" -js -sd /data -m 8222

# ── The core's worker ───────────────────────────────────────────────────────
# It consumes events and builds the projection the attention box reads. Without
# it the API answers 200 with an empty box, which looks like "nothing pending"
# and is not.
docker rm -f dop-worker 2>/dev/null || true
# The git root is a mounted volume, not the container's filesystem: the worker
# runs the project-knowledge git server (ADR-0028) and needs somewhere durable
# to write. Without the mount it starts, tries to create its root and dies.
docker run -d --name dop-worker --restart=always --network=host --memory=160m \
  -v /var/lib/dop/git:/var/lib/dop \
  -e DATABASE_URL="postgres://dop:$${PGPASS}@127.0.0.1:5432/dop?sslmode=disable" \
  -e NATS_URL="nats://127.0.0.1:4222" \
  -e SECRET_BACKEND=gcp \
  -e SECRET_PROJECT="$${PROJECT}" \
  -e GOOGLE_CLOUD_PROJECT="$${PROJECT}" \
  "$${AR}/dop-core:$${CORE_TAG}" worker

echo "dop-startup: done"
