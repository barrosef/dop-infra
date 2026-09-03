# A minimal Makefile — the only automation is the context guard.
# Normal operation is kubectl/k3d/k9s directly; here, only what needs
# protecting.

CLUSTER  := dop-local
CONTEXT  := k3d-$(CLUSTER)
NS       := dop-local
OVERLAY  := k3s/overlays/local

# k3d's registry: `localhost:5111` from OUTSIDE the cluster (push),
# `dop-registry:5000` from INSIDE (pull). They are the same registry under two
# names — the manifest uses the inside one, the `docker push` here uses the
# outside one.
REGISTRY := localhost:5111
REPOS    := ../

# The local environment's addresses, through k3d's load balancer (port 8080).
# They live in variables because the VITE_* values are baked into the bundle:
# whoever changes the host has to change it HERE and rebuild, not only in the
# manifest.
APP_BASE      := http://app.localtest.me:8080
APP_API_BASE  := http://api.localtest.me:8080
APP_AUTH_BASE := http://auth.localtest.me:8080

# A VERSIONED TAG, always. Rebuilding with the same tag does NOT guarantee the
# pod pulls the new layer: the kubelet sees the same name and reuses what it
# already has cached. When changing code: bump it HERE and in the corresponding
# Deployment's `image:`.
DEVBOX_TAG := 0.1.2
CORE_TAG := 0.1.0-9
API_TAG  := 0.1.0-5

.PHONY: image-devbox guard up down reset status logs ui cluster-up cluster-stop cluster-rm \
        images image-core image-api rollout

## guard: it refuses any operation outside the local cluster.
## This machine has clients' production contexts in its kubeconfig.
guard:
	@ctx=$$(kubectl config current-context 2>/dev/null); \
	if [ "$$ctx" != "$(CONTEXT)" ]; then \
		echo "ABORTED — the active context is '$$ctx', expected '$(CONTEXT)'."; \
		echo "Use: kubectl config use-context $(CONTEXT)"; \
		exit 1; \
	fi

up: guard                     ## apply the local environment
	kubectl apply -k $(OVERLAY)

down: guard                   ## remove the namespace (keeping the cluster)
	kubectl delete namespace $(NS) --ignore-not-found

reset: guard                  ## erase the data (PVCs) without destroying the cluster
	kubectl delete pvc -n $(NS) --all

status: guard                 ## a quick view of the environment
	@kubectl get pods,pvc,svc -n $(NS)

## one component's logs: make logs C=postgres | C=dop-core | C=dop-api
## It selects by label, not by StatefulSet: it serves both kinds of workload
## (Postgres is a sts, the core is a Deployment) and `C=dop-core` follows all
## three modes.
logs: guard
	kubectl logs -f -n $(NS) -l app=$(C) --all-containers --prefix --max-log-requests=10

ui: guard                     ## open k9s in the environment's namespace
	k9s -n $(NS) --context $(CONTEXT)

.PHONY: deploy-app
deploy-app: guard             ## build the cockpit and publish it to the emulated Hosting
	@# The local analogue of `firebase deploy --only hosting`: there is NO Docker
	@# image of the frontend, neither in production nor here. Hosting serves
	@# static files.
	@#
	@# The VITE_* values go into the BUILD because Vite substitutes them into the
	@# bundle — changing them afterwards requires a rebuild, and that holds the
	@# same on the real Firebase Hosting. PORT and BASE_PATH are required by
	@# vite.config.ts (inherited from Replit). PORT affects no build — only the
	@# dev server — but the config aborts without it. BASE_PATH is `/` because
	@# Hosting publishes at the domain's ROOT.
	PORT=5173 BASE_PATH=/ \
	VITE_API_BASE_URL=$(APP_API_BASE) \
	VITE_FIREBASE_AUTH_EMULATOR_URL=$(APP_AUTH_BASE) \
	VITE_FIREBASE_PROJECT_ID=dop-local \
	VITE_FIREBASE_API_KEY=fake-api-key \
	  pnpm -C $(REPOS)dop-app/artifacts/dop build
	@pod=$$(kubectl get pod -n $(NS) -l app=firebase -o jsonpath='{.items[0].metadata.name}'); \
	 echo "publishing to $$pod:/app/site"; \
	 kubectl exec -n $(NS) $$pod -- sh -c 'rm -rf /app/site/* /app/site/.[!.]* 2>/dev/null; true'; \
	 kubectl cp $(REPOS)dop-app/artifacts/dop/dist/public/. $(NS)/$$pod:/app/site/
	@echo "published: $(APP_BASE)"

.PHONY: token-ui
token-ui: guard               ## Headlamp's access token (http://k8s.localtest.me:8080)
	@kubectl create token headlamp -n $(NS) --duration=24h

## ── our components' images ─────────────────────────────────────────────────
## They need no guard: `docker push` talks to the registry, not to the cluster.

images: image-core image-api ## build and publish dop-core and dop-api to the registry

image-devbox:                 ## the image of the sandbox where the agent works
	docker build -t $(REGISTRY)/dop/devbox:$(DEVBOX_TAG) $(CURDIR)/images/devbox
	docker push $(REGISTRY)/dop/devbox:$(DEVBOX_TAG)

image-core:                   ## build and publish the core's image
	docker build -t $(REGISTRY)/dop/dop-core:$(CORE_TAG) \
	  --build-arg VERSION=$(CORE_TAG) $(REPOS)dop-core
	docker push $(REGISTRY)/dop/dop-core:$(CORE_TAG)

image-api:                    ## build and publish the BFF's image
	docker build -t $(REGISTRY)/dop/dop-api:$(API_TAG) \
	  --build-arg VERSION=$(API_TAG) $(REPOS)dop-api
	docker push $(REGISTRY)/dop/dop-api:$(API_TAG)

rollout: guard                ## wait for our Deployments to become ready
	@for d in dop-core-serve dop-core-worker dop-core-sched dop-api; do \
	  kubectl rollout status -n $(NS) deploy/$$d --timeout=120s; \
	done

cluster-up:                   ## create the k3d cluster from scratch
	k3d cluster create $(CLUSTER) \
	  --servers 1 --agents 0 \
	  --port "8080:80@loadbalancer" --port "8443:443@loadbalancer" \
	  --registry-create dop-registry:0.0.0.0:5111 \
	  --k3s-arg "--disable=metrics-server@server:0" \
	  --wait

cluster-stop:                 ## stop the cluster, preserving the data
	k3d cluster stop $(CLUSTER)

cluster-rm:                   ## destroy the cluster and the volumes
	k3d cluster delete $(CLUSTER)
