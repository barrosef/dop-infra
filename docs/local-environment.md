# The local environment — operating notes

## Life cycle

```bash
make cluster-up          # create from scratch
make images              # build and publish our components' images
make up                  # apply the environment
make cluster-stop        # stop, free memory, preserve the data
k3d cluster start dop-local
make reset               # erase the data (PVCs), keep the cluster
make cluster-rm          # destroy everything
```

Why there is no `dev.sh`: in a `docker compose` environment a script would be
needed to create the data directory, import conditionally, wait for readiness
and reset a root-owned volume. In Kubernetes that is a PVC, an `if` in the pod's
`command`, a `readinessProbe`, `terminationGracePeriodSeconds` and
`kubectl delete pvc` — all declarative. What is left is the context guard, which
lives in the `Makefile`.

## Our components' images

Two images of our own, built from the sibling repositories and published to
k3d's registry:

| Image | Source | Modes |
|---|---|---|
| `dop/dop-core` | `../dop-core/Dockerfile` (Go, multi-stage, a static binary) | `serve`, `worker`, `sched` (and `launcher`, not deployed yet) |
| `dop/dop-api` | `../dop-api/Dockerfile` (Python 3.13 + uv, multi-stage) | — |

```bash
make images              # both
make image-core          # the core only
make rollout             # wait for the Deployments to become ready
```

`localhost:5111` is the registry seen **from outside** (the `docker push`);
`dop-registry:5000` is the same registry seen **from inside** (the manifest's
`image:`). They are names for the same service — swapping one for the other is
an `ErrImagePull`.

**A versioned tag, always.** `CORE_TAG`/`API_TAG` in the `Makefile` and the
Deployment's `image:` go up together. See trap 5 below.

Both run as an **arbitrary non-root user** (an OKD/OpenShift requirement): the
permission lives on group 0, never on a named user — OKD assigns a UID that does
not exist in `/etc/passwd`.

## The cockpit on the Hosting emulator

**Firebase Hosting uses no Docker image** — neither in production nor here. In
production it is `firebase deploy --only hosting` sending static files to
Google's CDN. The local analogue is:

```bash
make deploy-app        # build the cockpit and publish it to app.localtest.me:8080
```

It runs `vite build` and copies `dist/public` into the emulator's pod. The site
lives on the PVC (not in an `emptyDir`), so it survives a pod restart — the same
way a real deploy survives.

| address | what |
|---|---|
| `http://app.localtest.me:8080` | the PUBLISHED cockpit, through the Hosting emulator |
| `http://api.localtest.me:8080` | the BFF |
| `http://auth.localtest.me:8080` | the Auth emulator |
| `http://storage.localtest.me:8080` | the Storage emulator |
| `http://k8s.localtest.me:8080` | Headlamp (token from `make token-ui`) |
| `http://localhost:4000` | the emulator UI — **no ingress**, it requires a port-forward |

**This does not replace `pnpm dev`.** The fast loop of whoever is working on the
screen is still Vite on `localhost:5173`. The emulated Hosting exists to
exercise what Vite does NOT and that only breaks in production:

- the SPA *rewrite* (`/demands/abc` has to return the `index.html`, not a 404);
- the `firebase.json` cache headers (`immutable` on the assets, `no-cache` on
  the `index.html`);
- **real CORS**, because the page comes from `app.` and calls `api.` — two
  origins. In production it will be the same, since the decision was to call the
  API through an absolute URL rather than a Hosting *rewrite*.

Both origins (`localhost:5173` and `app.localtest.me:8080`) are in the BFF's
`CORS_ORIGINS`. A closed list and not `*`: with `allow_credentials`, `*` is
refused by the browser, and loosening it here would hide in development an error
that would only show up later.

**The `VITE_*` values are baked into the bundle** by Vite — changing the API's
address requires a rebuild, changing the manifest is not enough. It holds the
same on the real Hosting; that is why the addresses live in `Makefile` variables
(`APP_API_BASE` and friends).

A known warning at boot: *"Could not fetch web app configuration"*. It is the
emulator saying it could not reach the real Firebase to assemble
`/__/firebase/init.js`. It affects nothing here — the cockpit reads its
configuration from the `VITE_*` values, not from `init.js`.

## Measured footprint (2026-08-31, the complete environment)

| | |
|---|---|
| the k3d server (Postgres + NATS + Firebase + dop-core ×3 + dop-api) | ~1220 MB |
| Headlamp (the web UI, optional — `k3s/tools/headlamp`) | ~48 MB |
| the load balancer | ~10 MB |
| the registry | ~12 MB |
| **total** | **~1.24 GB** |

Before our components the server sat at ~935 MB: the core's three modes add up
to ~40 MB (static Go) and the BFF ~90 MB (Python).

The emulator is the heaviest component (~300 MB — it is Java).
`k3d cluster stop dop-local` gives everything back to the machine while
preserving the data.

`metrics-server` is disabled to save ~50 MB; that is why `kubectl top` does not
work. Re-enable it by removing `--disable=metrics-server` when creating the
cluster.

## Access from the host

```bash
kubectl port-forward -n dop-local svc/postgres 5432:5432
kubectl port-forward -n dop-local svc/nats 4222:4222 8222:8222
kubectl port-forward -n dop-local svc/dop-api 8000:8000
kubectl port-forward -n dop-local svc/dop-core 9090:9090
kubectl port-forward -n dop-local svc/secretmanager 8085:9090   # the Secret Manager's gRPC
```

The `SecretStore`'s contract suite looks for the emulator at `127.0.0.1:8085`
(gRPC) — that is why the port-forward above uses that port. Any other one works,
with `SECRET_MANAGER_EMULATOR_HOST` pointing at it.

## Quick checks

```bash
# Postgres' extensions
kubectl exec -n dop-local postgres-0 -- psql -U dop -d dop -tAc \
  "select extname||' '||extversion from pg_extension order by extname;"

# JetStream is active
kubectl exec -n dop-local nats-0 -- wget -qO- http://localhost:8222/jsz

# the emulators are active (the hub)
kubectl exec -n dop-local firebase-0 -- wget -qO- http://localhost:4400/emulators

# the emulator's persisted data
kubectl exec -n dop-local firebase-0 -- ls /emulator-data/saved

# the BFF answers (the route is @public — a probe carries no token)
kubectl run curl --rm -i --restart=Never -n dop-local --image=curlimages/curl:8.11.1 \
  -- -sS http://dop-api.dop-local.svc:8000/healthz

# the core's gRPC surface, through reflection
kubectl port-forward -n dop-local svc/dop-core 9090:9090 &
grpcurl -plaintext localhost:9090 list
grpcurl -plaintext localhost:9090 grpc.health.v1.Health/Check

# the core's RBAC really is minimal
kubectl auth can-i create secrets -n dop-local \
  --as=system:serviceaccount:dop-local:dop-core     # yes
kubectl auth can-i create secrets -n kube-system \
  --as=system:serviceaccount:dop-local:dop-core     # no
```

## Internal addresses (how the components talk to each other)

| Service | Address |
|---|---|
| dop-core (gRPC) | `dop-core.dop-local.svc:9090` · health `:9091` |
| dop-api (the BFF) | `dop-api.dop-local.svc:8000` |
| Postgres | `postgres.dop-local.svc:5432` |
| NATS | `nats.dop-local.svc:4222` · monitor `:8222` |
| Firebase Auth | `firebase.dop-local.svc:9099` |
| Firebase Storage | `firebase.dop-local.svc:9199` |
| Emulator Hub / UI | `firebase.dop-local.svc:4400` / `:4000` |
| Secret Manager (gRPC) | `secretmanager.dop-local.svc:9090` |
| Secret Manager (REST, for debugging) | `secretmanager.dop-local.svc:8080` |

## Traps solved while building the emulators

Recorded because they cost time and would cost it again:

1. **A writable `HOME`** — `firebase-tools` writes config and cache; running as
   an arbitrary user with no `HOME` of its own, the start dies with "update
   check failed / unexpected error", a message that **does not point at the real
   cause**.
2. **JARs downloaded at build time** — `firebase setup:emulators:storage` and
   `:ui` in the Dockerfile. Without them the pod tries to download 52 MB on the
   first boot and fails when the network wobbles.
3. **JDK 21** — `firebase-tools` 14 warns about it and 15 will require it.
4. **The UI only comes up if some emulator has a UI.** With `--only
   auth,storage` and the probe pointing at port 4000, the pod never becomes
   ready. **The probe checks the hub (4400)**, which always exists.
5. **A versioned image tag** (`14.24.0-2`) — rebuilding with the same tag does
   not guarantee the pod pulls the new layer.

## Known limits of the Storage emulator

Found by running the `ObjectStore`'s contract suite against it. None is a defect
of our adapter: the filesystem adapter passes all 13 subtests, and the real GCS
accepts both cases below.

1. **It hangs on `Content-Type: application/json`.** With `uploadType=media` and
   that EXACT type, the emulator never answers — the connection stays open until
   the client's timeout. Reproducible with curl, the same body:

   | Content-Type | Response |
   |---|---|
   | `application/json` | **hangs** |
   | `application/json; charset=utf-8` | 400 |
   | `text/plain`, `text/json`, `application/xml`, `application/octet-stream` | 200 |

   The practical consequence: **storing JSON in the object store hangs in the
   local environment**. Whoever needs that before the emulator fixes it should
   write with a type it accepts.

2. **It falls over under concurrency.** Around 16 simultaneous operations bring
   the process down (it exits with code 2 and the pod restarts — you can watch
   the restart counter go up at that exact moment). Through the Ingress the
   symptom is a 502 from Traefik; through a port-forward, "connection refused" —
   two disguises for the same crash.

dop-core's `make test-contract-integration` target excludes those two subtests,
printing the reason. The alternative would be leaving them red forever, and a
chronically red suite is a suite nobody reads.

**The probes were loosened because of this.** `timeoutSeconds` was the default
1s, and the readiness had already timed out 7 times in two hours of an idle
environment: the hub answers on the same thread that serves uploads. Now it is
5s, and the liveness only restarts after 3 failures × 20s — restarting over
passing slowness erases the state of whoever is using it.

## The Secret Manager emulator — where it LIES about production

`k3s/emulators/secretmanager/`, the image
`ghcr.io/blackwell-systems/gcp-secret-manager-emulator-dual` 1.9.0 (Apache-2.0),
**pinned by digest** and **for development only**. Writing our own is the
ROADMAP's pending item **P-17**.

It exists because Google **publishes no Secret Manager emulator** — it publishes
one for Storage, Pub/Sub, Firestore, Bigtable and Spanner, but not for this one.
Without it the `SecretStore` port's `gcp` adapter would only be exercisable
against a real GCP project, and ADR-0001's two-adapter rule would be a dead
letter on precisely the port that keeps credentials.

**Read this list before trusting a green test.** Each item was verified against
the running emulator, and each is a place where the local environment is more
permissive than the real GCP — the same pattern that has already produced two
serious security failures in this project (the Auth emulator does not sign
tokens, and because of that the signature verification simply did not exist).
Where there is a defence, it is in
`dop-core/internal/adapter/secretstore/gcp.go`, which repeats this list.

| # | The emulator | The real GCP | The adapter's defence |
|---|---|---|---|
| 1 | accepts a `CreateSecret` **without** `replication` | the REST reference marks the field as *Required* (the `.proto`, newer, says *Optional* — they disagree with each other) | it always sends `Replication_Automatic`, explicitly |
| 2 | accepts **any** `secretId`: a dot, a space, a slash, uppercase, 300 characters — everything answered 200 | `[A-Za-z0-9_-]`, 255 maximum | it validates the name before every call |
| 3 | stored a value of **128 KiB** | 64 KiB per version | it refuses anything above 64 KiB before it leaves the machine |
| 4 | returns `dataCrc32c` **always 0** and ignores the checksum sent | it verifies on write and always returns it on read | it sends the CRC; on read it only checks when one arrives ≠ 0. The real integrity comes from the `Put`'s confirmation, which compares the bytes |
| 5 | `latest` **falls back**: with v3 disabled and v2 destroyed, it serves **v1** | `latest` is "an alias to the most recently **created** SecretVersion", regardless of state — if it is disabled/destroyed, the access **fails** | partial: by design, the highest-numbered version is always enabled. **It diverges if somebody disables one from outside** (the console, Terraform) |
| 6 | **0 ms** propagation | eventually consistent — see below | the `Put` waits for `latest` to catch up with the new version |
| 7 | **no quota at all** | `AddSecretVersion` 2 qps/120 qpm **per secret**; destroy/disable 1 qps **per version**; per project 90,000 accesses/min but only **600 reads/min and 600 writes/min** | a quota error becomes `KindUnavailable` (retryable). Nothing simulates the quota |
| 8 | **no IAM**: any caller reads any secret | IAM is the second barrier of the isolation between accounts | the `secretmanager-core-only` NetworkPolicy. No local test exercises IAM |
| 9 | deleting and recreating the same name works at once | `DeleteSecret` is irreversible and immediate, but the metadata is eventually consistent: recreating right after may give an `AlreadyExists` | none. The contract suite does exactly that cycle |
| 10 | **does not persist**: the image's `/data` stays empty, there is no import/export flag and a restart erases everything | durable | none — that is why the manifest is a `Deployment` with no PVC, and not a `StatefulSet` like Firebase's |

**The consequence of item 10:** on restarting the emulator's pod, **every
credential written in the local environment disappears**. It is not a bug; it is
what this emulator is.

### The most serious case: read-after-write

The `SecretStore` port promises, in guarantee 1, that a `Get` right after a
`Put` returns the value written. Google documents the opposite, at
<https://cloud.google.com/secret-manager/docs/reference/consistency>:

> "adding a secret version and then immediately accessing that secret version
> **by version number** is a strongly consistent operation" — and — "This doesn't
> apply when you access a secret version using aliases or `latest`". "Other
> operations within Secret Manager are eventually consistent", converging
> "typically within minutes, but may take a few hours".

The only strongly consistent path requires carrying the **version number**, and
`ports.SecretRef` has nowhere to keep it — versioning is deliberately outside
the port. That is: **on the real GCP, a `Get` right after a `Put` may
legitimately return `(nil, nil)`**, which by the port means "it does not exist".
The freshly written credential would appear as absent.

On the emulator that **never happens**, and the `1_immediate_read_after_write`
subtest passes in 0.01 s. It is the clearest example of a green test that proves
nothing.

What the adapter does meanwhile: it confirms the write by number (strong, always
works) and then **waits for the `latest` alias to catch up with the new
version**, capped at `SECRET_PROPAGATION_SECONDS` (30 s by default). The `Put`
does not return before that. If it does not converge, it returns
`KindUnavailable` saying exactly that — a slow `Put` and an explicit error are
better than a silent `Get` returning "it does not exist". **It is not a fix**:
it is the architectural decision becoming visible until somebody takes it
(either the port returns a version identifier from the `Put`, or guarantee 1
gets rewritten).

### What the contract suite does NOT cover

Found by breaking guarantees on purpose and watching what still passed:

- **A `Put` destroying the previous value is not verified.** Removing the
  destruction of the old versions leaves all seven subtests green: subtest 4
  only checks that the `Get` returns the new value, not that the old one stopped
  being readable. On the real GCP the old value would still be accessible by
  version number — "I rotated the leaked credential" meaning different things in
  each adapter.
- **Isolation by IAM is not verified** (item 8 in the table). What the suite
  proves about guarantee 5 is only the half that lives in the name.

## Access with no port-forward

The emulators also answer through k3d's load balancer, via the Ingress:

```
http://auth.localtest.me:8080      → the Auth emulator    (9099)
http://storage.localtest.me:8080   → the Storage emulator (9199)
```

`localtest.me` is a public domain that resolves to 127.0.0.1; with no DNS, use
`curl --resolve` or the `Host` header. Prefer this path to `kubectl
port-forward`: the port-forward drops under a burst of connections, and the test
then fails for the wrong reason — inventing an adapter defect where there is
none.

## Traps solved while bringing dop-core and dop-api up

1. **The cluster's CA is not in the public bundle.** The core's `SecretStore`
   talks to `https://kubernetes.default.svc`, whose certificate is signed by the
   **cluster's** CA — which does not exist in the image's `ca-certificates`. The
   symptom is cruel: the pod stays `Running` and `1/1` (nothing at boot touches
   the API) and the failure only shows up on the FIRST credential somebody tries
   to save, as `x509: certificate signed by unknown authority`.
   **Solved in the adapter, not in the manifest.** `secretstore.NewK8s` builds
   an `http.Client` that trusts the CA from
   `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` **in addition to** the
   public ones — the pod already receives that file from the kubelet, with no
   volume at all. Outside the cluster the file does not exist and the system pool
   still holds, so TLS with Firebase/GCS does not change.
   Knowing that the apiserver uses the cluster's CA is the **adapter's**
   knowledge: that is why `wire.go` no longer passes a `Client` — it used to pass
   a bare `http.Client`, which silently annulled the adapter's default. The
   `K8sConfig.Client` field remains only for injection in tests.
   Verified with no workaround at all in the Deployment: `SetCredential` writes
   the Secret and `kubectl get secret` returns the value.
2. **`httpGet` does not speak gRPC.** The `serve` probe points at `:9091`
   (HTTP), not at `:9090`: against the gRPC port the probe gets a protocol error
   and the pod never becomes ready. Every core mode exposes `/healthz` on
   `:9091` — `worker` and `sched` included, which have no gRPC port at all.
3. **The core's Service selects `mode: serve`.** A selector by `app: dop-core`
   alone would send calls to `worker` and `sched`, which do not listen on 9090 —
   and the symptom would be intermittent, the worst kind.
4. **uvicorn has a logger of its own.** Without `--log-level warning` it writes
   its own lines as plain text in the middle of `structlog`'s JSON, and the
   aggregated log stops being parseable. `PYTHONUNBUFFERED=1` for the same
   reason: without it the JSON stays stuck in the buffer and `kubectl logs` shows
   a mute pod.
5. **`sched` is `Recreate`.** With `RollingUpdate` the new pod comes up before
   the old one dies and for a few seconds there are TWO schedulers firing the
   same task.

## State

The environment is **complete and tested**: Postgres+pgvector, NATS JetStream,
the Firebase emulators (Auth + Storage), `dop-core`'s three modes and `dop-api`.
Persistence verified by restart; JSON logging verified on both ends; `serve`
connected to Postgres and NATS and answering `SERVING` on the gRPC health check.
`make ui` opens k9s; `http://k8s.localtest.me:8080` opens Headlamp (token from
`make token-ui`).

What is missing is deploying the core's **`launcher`** mode — it depends on the
execution cluster, which does not exist in the local environment yet.
