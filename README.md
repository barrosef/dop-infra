# dop-infra

The DOP platform's infrastructure: Terraform (QA/stage/prod) and the local k3d
environment.

> **State:** the local environment works; Terraform is structured, with no
> resources yet. Spec: `docs/superpowers/specs/dop-infra.md` in the
> meta-repository.

## The local environment

```bash
make cluster-up     # create the k3d cluster
make images         # build and publish dop-core and dop-api to the local registry
make up             # apply the environment
make status         # pods, PVCs and services
```

**Everything is declarative.** There is no orchestration script: persistence is
a PVC, waiting is a `readinessProbe`, a graceful shutdown is
`terminationGracePeriodSeconds`, a reset is `kubectl delete pvc`. The `Makefile`
exists for **one** reason — the context guard — and offers shortcuts for
convenience. Normal operation is `kubectl`, `k3d` and **k9s** directly.

**The context guard.** Every target that talks to a cluster refuses to run if
the active context is not `k3d-dop-local`. This machine has clients' production
contexts in its kubeconfig — the guard is not a convenience.

| Target | |
|---|---|
| `make up` / `down` | apply / remove the namespace |
| `make reset` | erase the PVCs (data) without destroying the cluster |
| `make status` | pods, PVCs, services |
| `make logs C=postgres` | one component's logs |
| `make ui` | open k9s in the namespace |
| `make images` | build and publish `dop-core` and `dop-api` to the local registry |
| `make image-core` / `image-api` | the same, for one component only |
| `make rollout` | wait for our components' Deployments to become ready |
| `make cluster-up` / `cluster-stop` / `cluster-rm` | the cluster's life cycle |

**A changed image requires a new tag.** `CORE_TAG` and `API_TAG` in the
`Makefile`, and the corresponding Deployment's `image:`, go up together.
Rebuilding with the same tag does not guarantee the pod pulls the new layer — a
trap recorded in `docs/local-environment.md`.

| Component | Internal address | Host |
|---|---|---|
| dop-core `serve` (gRPC) | `dop-core.dop-local.svc:9090` · health `:9091` | `kubectl port-forward` |
| dop-api (the BFF, REST+SSE) | `dop-api.dop-local.svc:8000` | the same |
| PostgreSQL 17 + pgvector | `postgres.dop-local.svc:5432` | `kubectl port-forward` |
| NATS JetStream | `nats.dop-local.svc:4222` · monitor `:8222` | the same |
| Firebase Auth | `firebase.dop-local.svc:9099` | the same |
| Firebase Storage | `firebase.dop-local.svc:9199` | the same |
| Emulator Hub / UI | `firebase.dop-local.svc:4400` / `:4000` | the same |
| Ingress (Traefik) | — | `localhost:8080` / `:8443` |
| Image registry | `dop-registry:5000` | `localhost:5111` |

The local Postgres credential: `dop` / `dop-local-dev` / database `dop` —
**development only**; in QA/stage/prod the credential comes from the
`SecretStore` (ADR-0001), never from a manifest.

## Resource ownership — who owns what

[ADR-0020](../../docs/adr/0020-firebase-emulators-and-single-owner.md)'s rule: a
resource created through the console stays out of the state and is reverted on
the next `apply`. **Nothing is created through the console.**

| Resource | Owner | Where it lives |
|---|---|---|
| GCP projects, IAM, enabled APIs | **Terraform** | `terraform/bootstrap` |
| Cloud Run, GKE, Cloud SQL, buckets, Secret Manager | **Terraform** | `terraform/stacks/platform` |
| Firebase Storage rules and indexes | **versioned files** (`firebase.json`, rules) | published by the CLI; Terraform references them, it does not recreate them |
| Firebase authentication providers | **Terraform** | declared explicitly; never changed through the console |
| The local environment's manifests | **Kustomize** | `k3s/` |

## Structure

```
terraform/
├── bootstrap/          projects, the state bucket, the CI's SAs — applied once
├── modules/            reusable blocks, with no environment values
└── stacks/platform/    the ONLY root module + envs/{qa,stage,prod}.tfvars
k3s/
├── base/               the namespace
├── services/           postgres · nats · dop-core · dop-api
├── emulators/          firebase (auth + storage)
└── overlays/local/     the local environment's composition
```

## Our components in the cluster

**dop-core** — ONE image, FOUR modes (ADR-0016); the mode is the container's
argument. Three Deployments today:

| Deployment | args | what it does |
|---|---|---|
| `dop-core-serve` | `serve` | the domain's gRPC on `:9090` |
| `dop-core-worker` | `worker` | event consumers, projections and the outbox relay |
| `dop-core-sched` | `sched` | periodic tasks — a single replica, `Recreate` strategy |

The fourth mode, **`launcher`**, was left out: it is a daemon of the
**execution** cluster (it provisions sandboxes), which does not exist in the
local environment yet. It comes in when there is an execution cluster for it to
govern.

The core has a **ServiceAccount of its own** with a `Role` (never a
`ClusterRole`) over `secrets` **in this namespace only** — the `SecretStore`
adapter keeps credentials in the Kubernetes API (ADR-0001), and a `ClusterRole`
would make the blast radius of a bug in the adapter the whole cluster.

**dop-api** — the BFF, `:8000`. With no ServiceAccount
(`automountServiceAccountToken: false`) and no database credential: it does not
talk to Postgres, it talks to the core. The probe uses `/healthz`, which is
`@public` — any other route would return a 401 to a probe with no token.
