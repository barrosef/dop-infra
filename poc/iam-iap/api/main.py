"""poc-api — the service behind IAP, and the screen that shows what it received.

THROWAWAY. It answers three questions and is then deleted:

1. What does IAP actually hand a Cloud Run service? Every claim, printed.
2. Does an Identity Platform CUSTOM CLAIM survive into that assertion? This is
   the one that decides whether roles could live there, and it is the reason
   this POC exists.
3. Can this service call a private one using its own identity, and which header
   carries it?
"""

import base64
import json
import os

import google.auth.transport.requests
import google.oauth2.id_token
import requests
from flask import Flask, request

app = Flask(__name__)

CORE_URL = os.environ.get("CORE_URL", "")


def claims_without_verifying(token: str) -> dict:
    """Decode a JWT payload for DISPLAY only — see the note in core/main.py."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as exc:  # noqa: BLE001
        return {"could_not_decode": str(exc)}


def call_core() -> dict:
    """Call the private service with THIS service's own identity.

    google.oauth2.id_token mints a token whose audience is the target URL; Cloud
    Run checks it against the invoker permission before the other process runs.
    Nothing here is a secret we hold — the identity comes from the runtime.

    It goes in X-Serverless-Authorization on purpose. Authorization is already
    carrying the person's credential in the real product, and Cloud Run reads
    this header precisely so the two do not fight. Proving that here is half the
    point of this POC.
    """
    if not CORE_URL:
        return {"skipped": "CORE_URL is not set"}
    try:
        auth_req = google.auth.transport.requests.Request()
        token = google.oauth2.id_token.fetch_id_token(auth_req, CORE_URL)
        response = requests.get(
            CORE_URL,
            headers={
                "X-Serverless-Authorization": f"Bearer {token}",
                "X-Person-Authorization": request.headers.get("Authorization", ""),
            },
            timeout=10,
        )
        return {"status": response.status_code, "body": response.json() if response.ok else response.text[:400]}
    except Exception as exc:  # noqa: BLE001
        return {"failed": str(exc)}


@app.route("/whoami.json")
def whoami_json():
    assertion = request.headers.get("X-Goog-IAP-JWT-Assertion", "")
    return {
        "iap_assertion_present": bool(assertion),
        # Everything IAP claims about this person. If a custom claim set in
        # Identity Platform appears here, roles COULD live there. If it does
        # not, the question is settled in the other direction.
        "iap_claims": claims_without_verifying(assertion) if assertion else None,
        # IAP also sets these two directly. They are the cheap read.
        "iap_email_header": request.headers.get("X-Goog-Authenticated-User-Email", ""),
        "iap_id_header": request.headers.get("X-Goog-Authenticated-User-Id", ""),
        "call_to_private_service": call_core(),
    }


@app.route("/")
def screen():
    """The simple screen. It renders what /whoami.json returns, and nothing else.

    Deliberately one file with no build step: what is being tested is the
    platform's behaviour, not a front end.
    """
    return """<!doctype html>
<meta charset="utf-8"><title>POC · IAM + IAP</title>
<style>
 body{background:#0E1116;color:#D8DEE7;font:14px/1.6 ui-sans-serif,system-ui;margin:0;padding:32px}
 h1{font-size:16px;margin:0 0 4px;color:#F0F4F9}
 p{color:#7C8798;margin:0 0 20px;font-size:12px}
 pre{background:#0B0E13;border:1px solid #232A34;border-radius:6px;padding:14px;
     overflow:auto;font:12px/1.6 ui-monospace,JetBrains Mono,monospace;color:#D8DEE7}
 .k{color:#3FB950}
</style>
<h1>POC · IAM + IAP</h1>
<p>What IAP handed this service, and whether this service could reach a private one.</p>
<pre id="out">loading…</pre>
<script>
fetch('/whoami.json', {credentials: 'include'})
  .then(r => r.json())
  .then(d => document.getElementById('out').textContent = JSON.stringify(d, null, 2))
  .catch(e => document.getElementById('out').textContent = 'failed: ' + e);
</script>
"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
