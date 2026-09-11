"""poc-core — the service nobody but poc-api may call.

THROWAWAY. This exists to answer one question and then be deleted: does Cloud
Run's IAM invoker permission actually keep everybody else out, and what does the
caller have to send to get in?

It is deployed with --no-allow-unauthenticated, so the platform refuses the
request before this process sees it. Whatever reaches here already passed that
check; what it prints is who Google says the caller was.
"""

import base64
import json
import os

from flask import Flask, jsonify, request

app = Flask(__name__)


def claims_without_verifying(token: str) -> dict:
    """Decode a JWT's payload for DISPLAY. It does not verify anything.

    That is acceptable here and nowhere else: this service is behind Cloud Run
    IAM, which already verified the token before the request arrived. Reading it
    again is for looking, not for deciding. A real service that made a decision
    from this would be trusting a string.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as exc:  # noqa: BLE001 — a POC prints the failure, it does not classify it
        return {"could_not_decode": str(exc)}


@app.route("/")
def whoami():
    auth = request.headers.get("Authorization", "")
    serverless = request.headers.get("X-Serverless-Authorization", "")

    return jsonify(
        {
            "service": "poc-core",
            "reached": True,
            # Which header carried the invoker's identity is the practical
            # question: Authorization is already spoken for by the person's
            # token in the real product, so if Cloud Run insists on it, the two
            # collide and X-Serverless-Authorization is the way out.
            "identity_came_in": "Authorization" if auth else ("X-Serverless-Authorization" if serverless else "neither"),
            "invoker": claims_without_verifying(auth or serverless) if (auth or serverless) else None,
            "person_token_present": bool(request.headers.get("X-Person-Authorization")),
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
