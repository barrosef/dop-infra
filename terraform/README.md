# Terraform

The DOP platform on GCP. One project per environment, one stack, one tfvars
file per environment — `dop-qa` today, `dop` (production) later from the same
code.

```
bootstrap/              the state bucket, run once, local state
stacks/platform/        everything else
  envs/qa.tfvars        what differs between environments
  envs/qa.backend       where that environment's state lives
  files/                the data VM's startup script, templated by the stack
```

## Running it

Some things cannot be codified — accepting terms, linking billing, creating an
OAuth App on GitHub, configuring Identity Platform's providers. They are in
[docs/qa-bootstrap-owner-steps.md](../docs/qa-bootstrap-owner-steps.md) and this
stack assumes they are done.

```bash
# once per project
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -var project=dop-qa

cd terraform/stacks/platform
terraform init -backend-config=envs/qa.backend
terraform plan -var-file=envs/qa.tfvars
```

Terraform reads Application Default Credentials, which are **not** the same
token as the `gcloud` CLI's. When every resource fails at once with
`invalid_rapt`, nothing is wrong with the code and nothing was read — the
credentials need `gcloud auth application-default login`.

## The first plan must be empty

The QA environment was built by hand before it was written down, so
`imports.tf` adopts what exists instead of recreating it. **A first `plan` that
proposes changes means the code disagrees with reality**, and reality wins until
somebody decides otherwise. Fix the code, not the environment.

## What this stack does not own

- **The default network and subnet.** Created by the auto-mode VPC. The stack
  asserts Private Google Access is on (`check` block in `network.tf`) rather
  than managing it — without it the data VM cannot reach Secret Manager and
  dies at boot with nothing useful in the log.
- **Secret values.** Terraform owns the container; a version written from here
  would sit in the state bucket forever.
- **Identity Platform's providers.** Console and owner steps.
- **The images.** Built and pushed by the Makefile. The stack only names a tag,
  and it must be a versioned one — see the note at the top of the Makefile
  about why a rebuilt tag is not a new image.
