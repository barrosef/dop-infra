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
what [ADR-0022](../../../../docs/adr/0016-the-core-verifies-its-callers.md) was
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

## 3b. What IAP actually hands the service — measured

A real sign-in produced this assertion:

```json
{
  "aud": "/projects/620588764334/locations/us-central1/services/poc-api",
  "azp": "/projects/620588764334/locations/us-central1/services/poc-api",
  "email": "ed.barros@digitalbusinessone.com",
  "exp": 1788870856, "iat": 1788870256,
  "hd": "digitalbusinessone.com",
  "identity_source": "GOOGLE",
  "iss": "https://cloud.google.com/iap",
  "sub": "accounts.google.com:110778210555756307913"
}
```

**Nine fields, and that is the whole shape.** It says who the person is and which
resource they reached. There is no room in it for an application role, and none
appeared — the set is fixed, not empty for want of configuration.

`identity_source: GOOGLE` is the sharpest line, and it took two wrong readings
to get right. Verified afterwards, with the project's configuration in hand:

**Firebase Authentication is configured on `dop-qa`** — e-mail/password and
`google.com` both enabled — **and IAP authenticated against Google anyway.**

> **Corrected on 2026-09-11, and the correction is the point.** This paragraph
> used to read *"Identity Platform IS initialized on dop-qa"*. It is not, and it
> never was. The owner noticed the GCP console still showing the product as
> disabled and asked why.
>
> Firebase Authentication and Identity Platform share one API
> (`identitytoolkit.googleapis.com`) and one permission namespace
> (`firebaseauth.*`). Identity Platform is an **enablement on top** of that
> shared surface, and it is what unlocks multi-tenancy, SAML/OIDC and blocking
> functions. Reading the shared API as proof of the product's state is the
> mistake, and this file made it twice.
>
> Measured, same project and same token, minutes apart:
>
> | call | result |
> |---|---|
> | `admin/v2/projects/dop-qa/config` | **200**, the whole configuration |
> | `v2/projects/dop-qa/tenants` | **400 `INVALID_PROJECT_ID`** |
> | `v2/projects/620588764334/tenants` | **400 `INVALID_PROJECT_ID`** |
>
> The project exists for Firebase Auth and does not exist for the Tenant
> Management service. The evidence was in this file the whole time and unread:
> the config comes back with `"multiTenant": {}` — empty, not absent.

That is the finding, and it is stronger than either earlier version. IAP does not
inherit the project's identity configuration. Using the product's own identities
means configuring IAP for **external identities**, deliberately, with the
separate authentication application the documentation describes. A project that
already has Identity Platform running, with the exact providers the product uses,
gets Google sign-in from IAP until somebody changes that on purpose.

The redirect went to `accounts.google.com/o/oauth2/v2/auth` with a client ID
belonging to IAP; the issuer is `https://cloud.google.com/iap`; the subject is
prefixed `accounts.google.com:`. The person was admitted as a Google Cloud
identity and authorized by an ordinary IAM grant
(`roles/iap.httpsResourceAccessor`) — Identity Platform nowhere in the path.

> **On the two wrong readings**, because the habit matters more than the fact.
> The first draft claimed Identity Platform was enabled and ignored, which was
> true but rested on the API being enabled — not the same thing as the product
> being configured. The second draft "corrected" it to say Identity Platform was
> never initialized, which was false, and was written after a `gcloud` command
> failed silently on an expired token. **A claim was turned into its opposite on
> the strength of a command that did not run.** Correcting on absence of evidence
> is how a document ends up less true than before it was fixed.

Two more measurements worth keeping:

- **`person_token_present: false`.** The person's own credential never reached
  the private service, because there was none: the browser authenticated with an
  **IAP session cookie**, not an `Authorization` header. IAP does not layer over
  the token this platform verifies — it **replaces** it. What was an argument is
  now an observation.
- **The e-mail header is prefixed with its source**:
  `accounts.google.com:ed.barros@...`. Reading it naively yields a malformed
  address.
- The assertion lives **ten minutes** (`exp - iat = 600`), refreshed by the
  proxy.

### What this did NOT settle

With external identities configured, IAP adds a `gcip` claim carrying the
Identity Platform token — and custom claims **would** travel inside it. So roles
could technically ride there.

What that would not change is the reason they should not: a role here is **per
account**, a claim **goes stale by up to an hour** while `RemoveMembership` takes
effect immediately, and **per-resource grants** do not fit in a claim at all. The
POC showed the default mode has no room; the model argument stands in either
mode.

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
