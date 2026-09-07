# POC · IAM and IAP on Cloud Run — what it measured

**Throwaway.** The code beside this file exists to answer questions and be
deleted. Nothing here is a component of the platform.

Run on 2026-09-07 in `dop-qa`, `us-central1`, with two Cloud Run services
(`poc-api`, `poc-core`) deployed from source.

---

## 1. IAM works — and deploying the obvious way would have made it theatre

`poc-core` was deployed with `--no-allow-unauthenticated`. An anonymous request
gets **403** before the process runs. That part behaved exactly as advertised.

The part that matters is what happened next. `poc-api` called it and **got 200
without anyone granting anything** — because a service deployed from source runs
as the project's default compute service account, and that account holds
**`roles/run.admin`**, which contains `run.invoker`.

So the first result was a false pass: the call succeeded because the caller could
invoke *everything*, not because it was allowed to invoke *this*.

Redeployed with a dedicated service account and nothing else:

| state | result |
|---|---|
| own SA, no grant | **403** |
| after `run.invoker` on `poc-core` specifically | **200** |

**Consequence for the real environment:** every Cloud Run service gets its own
service account. Running on the default one would leave the IAM boundary drawn
on paper and open in practice — the same failure the NetworkPolicy had, which is
what [ADR-0029](../../../../docs/adr/0029-the-core-verifies-its-callers.md) was
written about.

**IAM propagation took about a minute.** Long enough to look like a broken
deploy, short enough that people retry and blame something else.

## 2. `X-Serverless-Authorization` is confirmed

The ADR amendment predicted the collision: Cloud Run reads the invoker's token
from `Authorization`, and that header already carries the person's token.

Measured — the private service reported which header carried the identity:

```
identity_came_in: X-Serverless-Authorization
invoker:          poc-api-sa@dop-qa.iam.gserviceaccount.com
audience:         https://poc-core-...run.app
```

`Authorization` stayed free for the person's credential, which travelled beside
it untouched. The amendment was right, and it is now right for a measured
reason rather than a documented one.

## 3. The organization blocks public Cloud Run — and this would have stopped the real deploy

Making `poc-api` public failed. The cause is an **organization policy**,
`constraints/iam.allowedPolicyMemberDomains` (Domain Restricted Sharing),
allowing only customer `C012po69i`. `allUsers` belongs to no domain, so **no
Cloud Run service in this organization can be made public the usual way.**

The BFF must be reachable by any browser on the internet. Without a way around
this, the architecture does not deploy.

**The way around is a flag, not a policy exemption:** `--no-invoker-iam-check`
makes a service publicly reachable **without** an `allUsers` binding, so nothing
has to be granted to a principal the policy forbids. Verified: `poc-api` answers
200 to an anonymous request, while `poc-core` still answers 403.

This is the single most valuable thing the POC found, and it has nothing to do
with IAP. It would have surfaced as a confusing permission error in the middle
of the first real deployment.

## 4. IAP redirects to Google accounts

With `--iap`, an anonymous browser request returns **302 to
`accounts.google.com`** — Google identities, by default, out of the box.

Using Identity Platform identities instead is a separate configuration, and it
is not exposed on the Cloud Run resource through `gcloud iap settings`; the
documented flow for external identities is the App Engine-shaped one, with a
**separate authentication application** hosted apart from the protected service.

## 5. A non-browser call is rejected outright

The prediction under test was that IAP in front of the API breaks a single-page
app served from another origin. An API-style request produced:

```
HTTP 302 → accounts.google.com
Invalid IAP credentials: empty token
```

Not a 401 with a challenge the front end could answer — a redirect to a login
page, which an XHR cannot follow usefully, and a session cookie that would be
third-party for a cockpit on another origin.

**Confirmed:** IAP in front of the API breaks the front end it is meant to
protect.

---

## What this settles about roles

The question was whether user roles — dev, owner, admin — could live in Identity
Platform or IAP.

**Technically, a role fits in a custom claim.** That mechanism is real.

**It should not be the source of truth here**, for three reasons that are
properties of this product rather than of the technology:

1. **A role in DOP is per account, not per person.** The model is
   `Membership{UserID, AccountID, Role}` — the same person is `owner` of one
   account and `viewer` of another. Encoding that as a claim means a map inside
   the token, against a claims budget of about a kilobyte. The people who
   overflow it first are the ones in the most accounts, which is to say the most
   important ones.
2. **Claims go stale by up to an hour.** They refresh when the token refreshes.
   Removing somebody from an account would leave them `owner` for as long as
   their current token lives, and the code already written —
   `assertNotTheLastOwner`, `RemoveMembership` — takes effect immediately by
   design.
3. **Roles are not the whole answer.** The resolver already returns per-resource
   grants, which are tenant state and do not fit in a claim at all.

And IAP's own layer answers a different question entirely: *may this identity
reach this service?* It has no vocabulary for *is this person an owner of account
X* — and because anyone may sign up, its policy would have to admit every
authenticated user, deciding nothing.

**What does work:** the database stays the source of truth, and a claim may carry
a small, coarse, slow-moving flag — something like `platform_admin` — for a cheap
gate at the edge. A claim as a cache, never as an authority.

---

## What is adopted, and what is not

**Adopted — IAM between services.** Confirmed working and cheap, with two
conditions this POC discovered: each service runs as its own service account,
and the invoker's token travels in `X-Serverless-Authorization`.

**Adopted — `--no-invoker-iam-check` for the public service.** It is what lets
the BFF be public inside an organization that forbids `allUsers`.

**Not adopted — IAP.** Not on cost, which is zero. It redirects to a login the
product does not use, needs a second application to authenticate with the
identities the product does use, cannot express the authorization question that
matters here, and breaks a single-page app on another origin.

## Cleaning up

```bash
gcloud run services delete poc-api  --region=us-central1 --project=dop-qa --quiet
gcloud run services delete poc-core --region=us-central1 --project=dop-qa --quiet
gcloud iam service-accounts delete poc-api-sa@dop-qa.iam.gserviceaccount.com --project=dop-qa --quiet
```

The APIs enabled for this (`run`, `iap`, `identitytoolkit`, `cloudbuild`,
`artifactregistry`) stay — the real environment needs all but `iap`.

The three roles granted to the default compute service account
(`storage.objectUser`, `artifactregistry.writer`, `logging.logWriter`) also stay:
they are what `gcloud run deploy --source` needs on a project created after
Google moved to a least-privilege default, and the real deployment needs them
too.
