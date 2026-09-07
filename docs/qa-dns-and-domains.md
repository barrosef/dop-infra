# `qa.dop-t.com` — what to do in Hostinger and in GCP

The apex and `www` already point at GitHub Pages and are not touched here.
Everything below adds records **under `qa.`**, which is a separate branch of the
zone.

## No wildcard, and why

`*.qa.dop-t.com` as one record cannot work: the names underneath point at
different places — `auth.qa` at Firebase Hosting, `api.qa` at Cloud Run. A single
wildcard would have to send all of them to one entry point, and the only entry
point that can fan out that way is a global load balancer, which carries a
forwarding-rule charge every hour whether anybody uses it or not. That is the one
fixed cost this environment was designed to avoid.

Three names, three records. It is more typing once and nothing every month.

| name | points at | who gives you the value |
|---|---|---|
| `auth.qa.dop-t.com` | Firebase Hosting — the sign-in handler | the Firebase console |
| `api.qa.dop-t.com` | Cloud Run — the BFF | the Cloud Run console |
| `app.qa.dop-t.com` | the cockpit, when it has a home | later |

**Use the values the console gives you, not values from any document —
including this one.** Firebase and Cloud Run hand out the exact records for your
project, and they are what the verification checks against.

---

## Do this now, because it is the slow part

### 1. Prove to Google that the domain is yours

**Console:** https://search.google.com/search-console → **Add property** →
**Domain** (not "URL prefix").

Enter `dop-t.com`. Google returns a **TXT record**. Add it in Hostinger:

- **hPanel → Domains → DNS / Nameservers**
- Type `TXT`, Name `@`, Value = what Google gave you, TTL default

Then click **Verify**.

**Use the "Domain" property, not "URL prefix".** The domain property verifies
`dop-t.com` and **every subdomain under it at once** — which is what lets Cloud
Run map `api.qa.dop-t.com` later without a second verification. The URL-prefix
property verifies one address and would have to be repeated per name.

This is worth doing before anything else because DNS propagation is the only step
here measured in hours rather than minutes, and everything downstream waits on
it.

### 2. Create the project and attach billing

Steps 1 and 2 of [`qa-bootstrap-owner-steps.md`](qa-bootstrap-owner-steps.md).
Nothing in GCP can be created before this, and it does not depend on DNS.

---

## Then wait for me, because these need something deployed

A domain cannot be mapped to a service that does not exist. Both records below
are produced by a console **after** the thing they point at is running, and
inventing them in advance produces a name that resolves to nothing.

### 3. `auth.qa.dop-t.com` — after I create the Hosting site

**Firebase console → Hosting → Add custom domain** → `auth.qa.dop-t.com`.

Firebase returns records — normally a TXT to prove ownership, then two `A`
records. Add them in Hostinger with Name `auth.qa`.

**What this replaces.** Without it, sign-in happens on
`<project-id>.firebaseapp.com`, and that name appears in the browser's address
bar at the moment somebody is typing a password. With it, the whole flow stays on
`dop-t.com`, and the GitHub callback becomes:

```
https://auth.qa.dop-t.com/__/auth/handler
```

which is what goes into the GitHub OAuth App — **once**, if we do this before
creating it, and twice if we do not.

### 4. `api.qa.dop-t.com` — after I deploy the BFF

**Cloud Run console → the `dop-api` service → Manage custom domains → Add
mapping.**

For a subdomain, Cloud Run gives a `CNAME`. In Hostinger: Type `CNAME`, Name
`api.qa`, Value = what Cloud Run gave (a `ghs.googlehosted.com.`-style target),
TTL default.

Google then issues a managed certificate. It usually takes minutes; it can take
longer. Until it is issued the name answers with a certificate error, which looks
broken and is not.

**Mapping is by host, never by path.** Cloud Run cannot map `/api` to a service —
only the whole name. It does not need to: the BFF already serves under
`/api/v1/`, so `https://api.qa.dop-t.com/api/v1/accounts` is the address, with no
rewriting anywhere.

### 5. `app.qa.dop-t.com` — when the cockpit has a home

While the cockpit runs in Replit's preview, its own address is what serves it and
this record does not exist yet. What matters meanwhile is that **the Replit
address goes into Firebase's authorized-domain list** — see step 7 of the
bootstrap runbook. A missing entry there is the one failure that looks like the
product is broken.

---

## The order, and why it is not the obvious one

```
verify the domain  →  project + billing  →  Firebase Hosting + auth.qa
                                                      ↓
                                        the GitHub OAuth App, once
                                                      ↓
                              deploy the BFF  →  api.qa  →  the cockpit points at it
```

The GitHub OAuth App sits **after** `auth.qa` on purpose. Its callback URL is
recorded inside GitHub, and changing it later means going back into the app,
editing it, and hoping nobody forgot which environment they were in. Doing the
domain first costs one wait; doing it after costs a step that is easy to get
wrong quietly.

---

## What is Hostinger's, and what is not

**Hostinger holds DNS only.** Every record above is one line in its zone; nothing
else about this environment lives there. If DNS ever moves to another provider —
Cloud DNS, for instance, which Terraform could then own — the same records move
with it and nothing else changes.

**Do not remove or repoint the apex and `www`.** They serve the site through
GitHub Pages and have nothing to do with this. The names added here all sit under
`qa.` and cannot collide with them.
