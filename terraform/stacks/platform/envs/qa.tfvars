project = "dop-qa"
region  = "us-central1"
zone    = "us-central1-a"

core_image_tag = "0.1.0-15"
api_image_tag  = "0.1.0-8"

data_vm_internal_ip = "10.128.0.2"

# The cockpit runs on Replit and locally. Widen this deliberately, one origin at
# a time — a wildcard here is a credential leak waiting for a bad afternoon.
cors_origins = ["http://localhost:5173"]
