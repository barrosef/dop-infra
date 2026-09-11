# Secret access is project-wide, and it should not be

## What is true today

Three service accounts hold `roles/secretmanager.secretAccessor` **on the
project**:

| account | what it needs | what it can read |
|---|---|---|
| `dop-core-sa` | every secret the core uses | every secret |
| `dop-api-sa` | `dop-call-auth-key-bff` | every secret |
| `dop-vm` | `dop-postgres-password` | every secret |

The middle row is the problem. `dop-database-url` is in reach of the BFF's
identity, and [AGENTS.md](../../../AGENTS.md) invariant 2 says the BFF has no
database and no secret. Nothing in the BFF reads it — the violation is in what
the grant *permits*, not in what the code *does*, and that distinction is
exactly the one ADR-0029 was written about after the NetworkPolicy.

It is codified as it is, in `terraform/stacks/platform/secrets.tf`, so that
`terraform plan` is a faithful no-op against the live environment. Describing
the environment we wish we had is how a state file starts lying.

## The change

Replace the three project-level bindings with per-secret ones:

```hcl
resource "google_secret_manager_secret_iam_member" "core" {
  for_each  = toset(local.secrets)          # the core genuinely uses all of them
  project   = var.project
  secret_id = google_secret_manager_secret.this[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.core.email}"
}

resource "google_secret_manager_secret_iam_member" "api" {
  project   = var.project
  secret_id = google_secret_manager_secret.this["dop-call-auth-key-bff"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "vm" {
  project   = var.project
  secret_id = google_secret_manager_secret.this["dop-postgres-password"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
```

…and delete `google_project_iam_member.secret_accessor`.

## Why it is not in the same commit

Getting a binding wrong here does not fail loudly. A Cloud Run service that
cannot read a secret fails at **startup**, so the revision never serves and the
previous one keeps answering — the environment looks healthy while the deploy
is dead. The data VM is worse: it reads its password at boot, and a missing
grant surfaces as Postgres simply not being there.

So this is applied when the end-to-end smoke test can run immediately after,
and the order is: apply → force a new revision of both services → smoke test →
reboot the VM and confirm the three containers come back. Not before.
