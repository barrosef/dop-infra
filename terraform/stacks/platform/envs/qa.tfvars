project = "dop-qa"
region  = "us-central1"
zone    = "us-central1-a"

core_image_tag = "0.1.0-17"
api_image_tag  = "0.1.0-10"

data_vm_internal_ip = "10.128.0.2"

# The e-mail channel. OneSignal covers push, e-mail and SMS; this is the e-mail
# half. With no app id or key the adapter runs in DRY RUN — it renders and logs
# the message instead of sending it, which is enough to prove the chain and not
# enough to reach anybody.
mail_backend = "onesignal"

# The BFF under its own name. Needs dop-t.com verified for the account running
# Terraform — it is, since Firebase Hosting's verification propagated.
api_custom_domain = "api.qa.dop-t.com"

# Where the e-mail action links point. Firebase mints them on
# dop-qa.firebaseapp.com and refuses to let this project change that
# (EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED); the BFF rewrites the host, because the
# handler is served on this domain too.
firebase_auth_domain = "auth.qa.dop-t.com"

# The OneSignal application. This id is NOT a credential — OneSignal ships it
# inside every client SDK, web and mobile — so it lives here like any other
# environment fact. The REST key is a credential and lives in Secret Manager;
# Terraform owns its container and never its value.
onesignal_app_id = "0e30a77e-5dd1-44e8-989f-b25150bd6432"

# The cockpit runs on Replit and locally. Widened deliberately, one origin at a
# time — a wildcard here is a credential leak waiting for a bad afternoon.
#
# The Replit entry is the PREVIEW host, which is per-repl: replit.com is the
# editor and never appears as an Origin, because the app itself is served from
# *.replit.dev inside an iframe. A new repl means a new line here.
cors_origins = [
  "http://localhost:5173",
  "https://e3475181-277f-4cde-acd6-615cdcb94884-00-2srzlp15mrsc5.janeway.replit.dev",
]
