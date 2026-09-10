# The BFF can read every identity in the project, and it should not

## What was granted, and why

`dop-api-sa` holds `roles/firebaseauth.admin` on `dop-qa`
(`terraform/stacks/platform/identity.tf`).

The BFF needs it for exactly one call: asking Identity Platform to mint a
verification link with `returnOobLink` and **not** send it (spec SP-0 D-7). No
narrower predefined role exists — Identity Platform ships `admin` and `viewer`,
and minting an action link needs `admin`.

So the grant buys one method and pays for all of them: with it, the BFF can
read, modify, disable and delete **every** identity in the project.

## Why that is worse here than the same grant elsewhere

`dop-api` is the one service in this architecture that is reachable from the
open internet. It is public deliberately — the cockpit calls it from a browser,
and `--no-invoker-iam-check` is what makes that possible inside an organization
that forbids `allUsers`.

Every other privileged component is private: `dop-core` answers only to the
BFF's service account, and the data VM has no external address at all. This
grant inverts that shape. A compromise of the edge stops being "an attacker can
call the API as themselves" and becomes "an attacker owns every account".

It was accepted with eyes open, in a QA project that holds nobody's data, to
unblock the end-to-end proof of the sign-up flow. It should not travel to
production.

## The narrower shape

**Move the minting into the core.** The core already holds the vault, already
talks to privileged APIs, and is not internet-facing.

Concretely:

1. A narrow port in the domain — one method, something like
   `VerificationLinkMinter.LinkFor(ctx, email) (string, error)`. Not a method on
   `ports.IdentityProvider`: that port is implemented by the OIDC adapter too,
   and Keycloak's equivalent is a different gesture entirely. A port with one
   implementation and one honest `Unimplemented` is better than a port that
   forces a lie.
2. The Firebase adapter implements it with the same REST call the BFF makes
   today (`accounts:sendOobCode`, `returnOobLink: true`), authenticated by the
   core's own service account.
3. `roles/firebaseauth.admin` moves from `dop-api-sa` to `dop-core-sa`, and this
   file's grant is deleted.
4. `app/platform/security/firebase_admin.py` is deleted from the BFF.

## The second thing it fixes, which is not about privilege

`SendEmailVerificationRequest` currently carries `link`. The core receives a URL
from its caller and puts it inside a message with the platform's branding — the
`.proto` says so in a comment, and calls it a phishing surface bounded only by
the fact that callers are signed.

If the core mints the link, **that field goes away**. The bound stops being "we
trust the callers" and becomes "there is nothing to trust them about". That is a
better reason to delete the field than the privilege is.

## How to tell the debt grew

The grant should stay removable in one line. If a second thing in the BFF starts
depending on Firebase Admin — password reset is the obvious candidate, and it is
in the same spec — then this stops being a line to delete and becomes a
migration. Password reset should be built on the core side from the start, for
that reason alone.
