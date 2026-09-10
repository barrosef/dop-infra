#!/usr/bin/env bash
# Puts the OneSignal REST key into Secret Manager, and nowhere else.
#
#   scripts/load-onesignal-key.sh [project] [path-to-credentials-file]
#
# The key never reaches a terminal, a log or this repository. Terraform owns the
# secret's CONTAINER (secrets.tf) and never its value: a version written from
# Terraform lives forever in the state file, and the state file is a bucket that
# gets shared.
#
# Run `terraform apply` FIRST so the container exists — this script only adds a
# version to it, and says so plainly if it is missing.
set -euo pipefail

PROJECT="${1:-dop-qa}"
FILE="${2:-$HOME/Documents/dop-one-signal-api-key.txt}"
SECRET="dop-onesignal-api-key"

[ -f "$FILE" ] || { echo "credentials file not found: $FILE"; exit 1; }

# The label in the file, not a position: a file whose lines get reordered must
# not silently load the app id as the credential.
KEY=$(sed -n 's/^api-secret-key[:=][[:space:]]*//p' "$FILE" | head -1)
[ -n "$KEY" ] || { echo "no 'api-secret-key' line in $FILE"; exit 1; }

case "$KEY" in
  os_v2_*) ;;
  *) echo "the key does not start with os_v2_ — that is OneSignal's current"
     echo "format, and an older one needs ONESIGNAL_AUTH_SCHEME=Basic instead"
     echo "of the default Key. Refusing rather than shipping a 401 that reads"
     echo "exactly like a bad credential."; exit 1 ;;
esac

gcloud secrets describe "$SECRET" --project "$PROJECT" >/dev/null 2>&1 || {
  echo "the secret $SECRET does not exist in $PROJECT — run terraform apply first"
  exit 1
}

printf '%s' "$KEY" | gcloud secrets versions add "$SECRET" \
  --project "$PROJECT" --data-file=- >/dev/null

echo "loaded: $SECRET now has $(gcloud secrets versions list "$SECRET" \
  --project "$PROJECT" --format='value(name)' | wc -l) version(s)"
echo "the core reads it as ONESIGNAL_API_KEY at the next revision."
