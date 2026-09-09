#!/usr/bin/env bash
# End-to-end check of a deployed environment, from a real sign-in to a real row
# in the database.
#
#   scripts/qa-smoke.sh [project] [email] [password]
#
# What makes this worth having: it is the ONLY test that exercises the Firebase
# signature path. The emulator issues tokens with alg:none and signs nothing,
# and the contract suite serves its own X.509 certificates so it can run with no
# internet. Between the two, the address the core fetches Google's signing keys
# from was never exercised until a real person's token hit a real environment —
# and it was wrong. Every real token was refused for a day.
#
# It needs an operator credential (`gcloud auth login`), because there is no
# inbox here and the e-mail has to be verified the way an operator would.
set -euo pipefail

PROJECT="${1:-dop-qa}"
REGION="${REGION:-us-central1}"
EMAIL="${2:-smoke-$(date +%s)@example.com}"
PASS="${3:-smoke-password-$(date +%s)}"

API=$(gcloud run services describe dop-api --region "$REGION" --project "$PROJECT" \
        --format='value(status.url)')
[ -n "$API" ] || { echo "dop-api is not deployed in $PROJECT/$REGION"; exit 1; }

# The browser key, looked up rather than pasted: it is per-project, and a
# hardcoded one silently tests the wrong environment.
KEY_ID=$(gcloud services api-keys list --project "$PROJECT" \
           --format='value(uid)' --filter='displayName~Browser' | head -1)
[ -n "$KEY_ID" ] || { echo "no browser API key in $PROJECT"; exit 1; }
KEY=$(gcloud services api-keys get-key-string "$KEY_ID" --project "$PROJECT" \
        --format='value(keyString)')

idtoken() { python3 -c 'import sys,json; print(json.load(sys.stdin).get("idToken",""))'; }

echo "== $PROJECT — signing up $EMAIL"
TOKEN=$(curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"returnSecureToken\":true}" | idtoken)
[ -n "$TOKEN" ] || { echo "sign-up returned no idToken"; exit 1; }

LOCAL_ID=$(curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=$KEY" \
  -H 'Content-Type: application/json' -d "{\"idToken\":\"$TOKEN\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["users"][0]["localId"])')

# The core refuses an e-mail/password sign-up whose address was never verified
# (US-7). That rule is correct, and it is also a wall for a script with no
# inbox — so the verification happens through the ADMIN API, deliberately.
#
# X-Goog-User-Project is NOT optional. identitytoolkit bills the call to a quota
# project and a user credential has none by default; without the header the
# request is attributed to gcloud's own shared project and comes back
# 403 SERVICE_DISABLED, which reads exactly like a missing permission.
echo "== marking the e-mail verified (localId $LOCAL_ID)"
CODE=$(curl -s -o /tmp/qa-smoke-admin.json -w '%{http_code}' -X POST \
  "https://identitytoolkit.googleapis.com/v1/projects/$PROJECT/accounts:update" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: $PROJECT" \
  -H 'Content-Type: application/json' \
  -d "{\"localId\":\"$LOCAL_ID\",\"emailVerified\":true}")
if [ "$CODE" != "200" ]; then
  # Stop, loudly. Carrying on would call the API with an unverified token and
  # report the core's correct 412 as though it were the news — hiding the step
  # that actually failed. A previous version of this script printed
  # "e-mail verified" immediately after a 403.
  echo "admin update FAILED: HTTP $CODE"; head -c 600 /tmp/qa-smoke-admin.json; exit 1
fi

# A fresh sign-in, because email_verified travels INSIDE the token: the one
# minted before the update says false forever.
TOKEN=$(curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"returnSecureToken\":true}" | idtoken)
VERIFIED=$(python3 -c "
import base64,json,sys
p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get('email_verified'))" "$TOKEN")
[ "$VERIFIED" = "True" ] || { echo "the token still says unverified"; exit 1; }
echo "   token ok, email_verified=$VERIFIED"

fail=0
check() { # name, url, jq-ish python assertion
  local name="$1" url="$2" assertion="$3"
  local body code
  body=$(curl -s -o /tmp/qa-smoke-body.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
  code="$body"; body=$(cat /tmp/qa-smoke-body.json)
  if [ "$code" != "200" ]; then
    echo "FAIL $name: HTTP $code $body"; fail=1; return
  fi
  if ! python3 -c "$assertion" "$body" 2>/dev/null; then
    echo "FAIL $name: 200 but the body says nothing happened: $body"; fail=1; return
  fi
  echo "  ok $name"
}

echo "== the API"
check "GET /api/v1/me" "$API/api/v1/me" \
  'import sys,json; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("user_id") else 1)'
# An empty list here would be a 200 that says the write side never ran: the
# personal account is born with the user (identity.Service.EnsureUser).
check "GET /api/v1/accounts" "$API/api/v1/accounts" \
  'import sys,json; d=json.loads(sys.argv[1]); sys.exit(0 if len(d)==1 and d[0]["kind"]=="personal" else 1)'

[ "$fail" = 0 ] && echo "== the chain works: Identity Platform -> BFF -> IAM -> core -> Postgres"
exit "$fail"
