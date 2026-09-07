# Bootstrapping `dop-qa` — the steps only the owner can take

Everything else in this environment is Terraform. These seven steps are not:
they need a human accepting terms, owning a billing account, and holding
credentials in GitHub and Google that no service account can hold for them.

**Do them in this order.** The order is not a preference — each step produces a
value the next one needs, and taking them out of order means going back.

> **Never paste a client secret into a chat, a commit or an issue.** Every secret
> below travels from the console where it is created straight into the console
> where it is used, or into Secret Manager. It does not pass through anywhere
> else.

---

## 1. Create the project and attach billing

**Console:** https://console.cloud.google.com/projectcreate

- **Project name:** `dop-qa`
- **Project ID:** `dop-qa` if it is free. **It may not be** — project IDs are
  globally unique across all of Google Cloud, and short ones are usually taken.
  If it is taken, use `dop-qa-<something short and ours>`, and tell me the ID you
  chose: it goes into `qa.tfvars` and into every command afterwards. The
  *display name* stays `dop-qa` either way.
- **Organization:** the one belonging to the company, if the account has one.

Then attach billing: **Billing → Link a billing account**.

Billing is not optional here even though the target is the free tier. Compute
Engine, Cloud Run and Artifact Registry all refuse to run on a project with no
billing account, and the Always Free allowances only apply on a project that has
one. What keeps the cost at zero is staying inside the allowances, not the
absence of a card.

**Worth setting now, while you are in there:** a **budget with an alert** at a
low value — five dollars is enough. It does not cap anything; it e-mails you the
day something starts costing. In a free-tier environment, the first dollar is the
signal that something is misconfigured.

**Check before moving on:** the project appears at
https://console.cloud.google.com/billing/linkedaccount with a billing account
attached.

---

## 2. Turn Firebase on for the project

**Console:** https://console.firebase.google.com → **Add project** → choose the
**existing** `dop-qa` project rather than creating a new one.

Creating a separate Firebase project instead of adding Firebase to this one is
the common mistake here, and it produces two projects that look right and do not
talk to each other.

Google Analytics can be declined; nothing in DOP uses it.

**What this produces, and why the next steps need it:** the project's
authentication domain, `https://<project-id>.firebaseapp.com`. Step 5's callback
URL is built from it.

**Check before moving on:** **Build → Authentication → Get started** exists in the
Firebase console for this project.

---

## 3. Configure the Google consent screen

**Console:** https://console.cloud.google.com/auth/overview (recent consoles call
this **Google Auth Platform**; older ones, **OAuth consent screen**).

- **Audience:** *External*. *Internal* only exists with Google Workspace and
  would restrict sign-in to the company's own domain.
- **App name:** `DOP` — this is the name a person reads on the Google sign-in
  screen, so it is product copy, not an identifier.
- **User support e-mail** and **developer contact e-mail**: yours.
- **Authorized domains:** `<project-id>.firebaseapp.com`. Add the product's own
  domain later, when it exists.

**Publishing status — a real decision, not a formality.** Leave it in
**Testing**:

- *Testing* allows up to 100 named test users, needs no Google review, and works
  today. The cost is that a refresh token expires after **seven days**, so a
  tester signs in again once a week.
- *In production* removes both limits and triggers Google's verification, which
  takes days and asks for a privacy policy and a domain you own.

For a QA environment, Testing is right, and the weekly re-login is a fact worth
knowing before somebody reports it as a bug.

**Add every person who will test as a test user**, including yourself. Somebody
not on that list gets a refusal that reads like a broken app.

**Check before moving on:** the consent screen shows *Testing* and your e-mail is
in the test-user list.

---

## 4. Enable e-mail and Google sign-in

**Console:** Firebase → **Authentication → Sign-in method**

- **E-mail/Password:** enable. Leave *E-mail link (passwordless)* off — nothing
  in the product uses it.
- **Google:** enable. It uses the consent screen from step 3 and needs nothing
  pasted.

**Then, and this one matters more than it looks:** under
**Authentication → Settings → User actions**, make sure **"Link accounts that use
the same e-mail address"** is **on**.

The whole account-linking behaviour in the cockpit depends on it. With it off,
somebody who signed up with Google and later clicks GitHub becomes a second
credential — and because the `users` table has a unique index on the e-mail, the
core refuses with a conflict instead of linking them. The screens for that flow
are already built and tested; this setting is what makes them reachable.

**Check before moving on:** both providers show *Enabled*, and the linking
setting is on.

---

## 5. Create the GitHub OAuth App

**Console:** https://github.com/organizations/Digital-Business-One/settings/applications
→ **New OAuth App**

It must be an **OAuth App**, not a **GitHub App**. They are different products
with different screens. The GitHub App is what
[ADR-0003](../../../docs/adr/0003-organization-credential-human-authorship.md)
uses to *act* on repositories — installed per organization, with its own
permissions. That is separate work, later. What sign-in needs is an OAuth App.

**One OAuth App per environment, not one shared.** Since August 2026 a GitHub
OAuth App accepts up to ten redirect URIs, so a single app *could* serve QA and
production. It should not, and the reason is the client secret: a shared app
means both environments hold the same credential, and QA is by definition where
credentials leak — looser access, more people, disposable data, deploys without
ceremony. Whoever reads QA's secret can impersonate production's sign-in, and
rotating after a QA incident would force a production change in the same move.
That is the exact path §3 of the infra spec closes for GCP projects, reopened at
the identity layer.

It also buys something: with one app per environment, the authorization screen
can say **which** environment somebody is authorizing.

- **Application name:** `DOP (QA)` — read by a person on GitHub's authorization
  screen, and the only signal telling a tester which environment they are
  entering. Production's app is `DOP`.
- **Homepage URL:** the product's URL when it exists; for now
  `https://<project-id>.firebaseapp.com` is honest and valid.
- **Authorization callback URL:** exactly

  ```
  https://<project-id>.firebaseapp.com/__/auth/handler
  ```

  Two underscores before `auth`. A wrong callback fails at the end of the flow,
  after the person has already authorized — which reads as the product being
  broken rather than misconfigured.

**Check whether wildcard matching is on, and turn it off.** GitHub added
per-URI wildcard matching in August 2026, and apps that existed before then had
it switched on for their single callback URL. A new app should not need it: this
callback is one exact URL on one exact host. A wildcard here widens where GitHub
is willing to send an authorization code, which is attack surface bought for
nothing.

Then **Generate a new client secret**. GitHub shows it **once**. Copy it and go
straight to step 6; do not store it anywhere on the way.

---

## 6. Paste GitHub's credentials into Firebase

**Console:** Firebase → **Authentication → Sign-in method → GitHub → Enable**

Paste the **Client ID** and the **Client secret** from step 5. Firebase shows the
callback URL on this same screen — it must be identical to what you typed into
GitHub. If they differ, fix GitHub's, not Firebase's.

**Check:** the three providers — E-mail/Password, Google, GitHub — all show
*Enabled*.

---

## 7. Authorize the domains that will sign people in

**Console:** Firebase → **Authentication → Settings → Authorized domains**

`localhost` and `<project-id>.firebaseapp.com` are there by default. Add:

- **the Replit preview's domain**, when it exists;
- the product's own domain, later.

**Firebase does not accept wildcards here.** Each domain is listed literally, so
a preview URL that changes needs re-adding.

A domain that is missing produces `auth/unauthorized-domain`, and the cockpit
already handles it: the message says sign-in is not configured for that address
and that we have been alerted, and it deliberately does **not** tell the person
to contact anybody — nobody they can reach can fix it. If that message appears in
testing, this list is the place to look.

---

## What to send me when you are done

- **The project ID**, if it is not `dop-qa`.
- **The billing account ID** (`gcloud billing accounts list`, or the console).
- **The Replit preview domain**, when you have it.

Nothing else. The GitHub client secret stays between GitHub and Firebase, and
never appears in a message.

## What I do next

Enable the APIs, create the free `e2-micro` with Postgres, NATS and the worker,
publish the images, deploy the two Cloud Run services with Direct VPC egress,
and put the database password and the `callauth` keys into Secret Manager — all
of it as Terraform, in `terraform/stacks/platform`, applied with `ENV=qa`.
