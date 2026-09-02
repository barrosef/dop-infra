# Headlamp — the cluster's web UI

Why Headlamp and not Rancher: Rancher is a product for managing a FLEET of
clusters and asks for ~1 GB for itself alone — more than the whole DOP
environment consumes today (~1.24 GB). Here the need is to look at ONE
development cluster. Headlamp (CNCF) does that in **48 MB** — measured on k3d
on 2026-09-01, not estimated.

`k9s` (`make ui`) is still the fastest path in the terminal. The two coexist:
k9s is better for operating, Headlamp for SEEING — the resource tree, the YAML
side by side, logs from several pods, and a link you can send to somebody.

Access: `http://k8s.localtest.me:8080`, through the same k3d load balancer that
serves the emulators — with no port-forward, for the same reason documented in
`emulators/firebase/ingress.yaml`.

The entry token comes from `make token-ui`.

## Permissions

The ServiceAccount is `cluster-admin`. That is acceptable HERE and nowhere
else: it is a disposable k3d cluster, on the developer's machine, with nobody's
data on it. If this directory ever ends up in an overlay that is not `local`,
the rule has to become read-only RBAC — and that is why it is NOT in `base`,
but referenced only by the local overlay.
