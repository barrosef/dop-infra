project = "dop-qa"
region  = "us-central1"
zone    = "us-central1-a"

core_image_tag = "0.1.0-15"
api_image_tag  = "0.1.0-8"

data_vm_internal_ip = "10.128.0.2"

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
