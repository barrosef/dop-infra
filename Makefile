# Makefile mínimo — a única automação é a guarda de contexto.
# Operação normal é kubectl/k3d/k9s direto; aqui só o que precisa de proteção.

CLUSTER  := dop-local
CONTEXT  := k3d-$(CLUSTER)
NS       := dop-local
OVERLAY  := k3s/overlays/local

# Registry do k3d: `localhost:5111` de FORA do cluster (push), `dop-registry:5000`
# de DENTRO (pull). São o mesmo registry por dois nomes — o manifesto usa o de
# dentro, o `docker push` daqui usa o de fora.
REGISTRY := localhost:5111
REPOS    := ../

# Endereços do ambiente local, pelo loadbalancer do k3d (porta 8080). Ficam em
# variável porque as VITE_* são embutidas no bundle: quem mudar o host precisa
# mudar AQUI e reconstruir, não só no manifesto.
APP_BASE      := http://app.localtest.me:8080
APP_API_BASE  := http://api.localtest.me:8080
APP_AUTH_BASE := http://auth.localtest.me:8080

# TAG VERSIONADA, sempre. Reconstruir com a mesma tag NÃO garante que o pod puxe
# a camada nova: o kubelet vê o mesmo nome e reaproveita o que já tem em cache.
# Ao mudar código: incremente aqui E na `image:` do Deployment correspondente.
DEVBOX_TAG := 0.1.0
CORE_TAG := 0.1.0-5
API_TAG  := 0.1.0-3

.PHONY: image-devbox guard up down reset status logs ui cluster-up cluster-stop cluster-rm \
        images image-core image-api rollout

## guard: recusa qualquer operação fora do cluster local.
## Esta máquina tem contextos de produção de clientes no kubeconfig.
guard:
	@ctx=$$(kubectl config current-context 2>/dev/null); \
	if [ "$$ctx" != "$(CONTEXT)" ]; then \
		echo "ABORTADO — contexto ativo é '$$ctx', esperado '$(CONTEXT)'."; \
		echo "Use: kubectl config use-context $(CONTEXT)"; \
		exit 1; \
	fi

up: guard                     ## aplica o ambiente local
	kubectl apply -k $(OVERLAY)

down: guard                   ## remove o namespace (mantém o cluster)
	kubectl delete namespace $(NS) --ignore-not-found

reset: guard                  ## apaga os dados (PVCs) sem destruir o cluster
	kubectl delete pvc -n $(NS) --all

status: guard                 ## visão rápida do ambiente
	@kubectl get pods,pvc,svc -n $(NS)

## logs de um componente: make logs C=postgres | C=dop-core | C=dop-api
## Seleciona por rótulo, não por StatefulSet: serve para os dois tipos de carga
## (o Postgres é sts, o core é Deployment) e `C=dop-core` segue os três modos.
logs: guard
	kubectl logs -f -n $(NS) -l app=$(C) --all-containers --prefix --max-log-requests=10

ui: guard                     ## abre o k9s no namespace do ambiente
	k9s -n $(NS) --context $(CONTEXT)

.PHONY: deploy-app
deploy-app: guard             ## constrói o cockpit e publica no Hosting emulado
	@# O análogo local de `firebase deploy --only hosting`: NÃO há imagem Docker
	@# do frontend, nem em produção nem aqui. Hosting serve arquivo estático.
	@#
	@# As VITE_* entram na BUILD porque o Vite as substitui no bundle — mudá-las
	@# depois exige reconstruir, e isso vale igual no Firebase Hosting real.
	@# PORT e BASE_PATH são exigidos pelo vite.config.ts (herança do Replit).
	@# PORT não afeta build nenhum — só o dev server —, mas o config aborta sem
	@# ele. BASE_PATH é `/` porque o Hosting publica na RAIZ do domínio.
	PORT=5173 BASE_PATH=/ \
	VITE_API_BASE_URL=$(APP_API_BASE) \
	VITE_FIREBASE_AUTH_EMULATOR_URL=$(APP_AUTH_BASE) \
	VITE_FIREBASE_PROJECT_ID=dop-local \
	VITE_FIREBASE_API_KEY=fake-api-key \
	  pnpm -C $(REPOS)dop-app/artifacts/dop build
	@pod=$$(kubectl get pod -n $(NS) -l app=firebase -o jsonpath='{.items[0].metadata.name}'); \
	 echo "publicando em $$pod:/app/site"; \
	 kubectl exec -n $(NS) $$pod -- sh -c 'rm -rf /app/site/* /app/site/.[!.]* 2>/dev/null; true'; \
	 kubectl cp $(REPOS)dop-app/artifacts/dop/dist/public/. $(NS)/$$pod:/app/site/
	@echo "publicado: $(APP_BASE)"

.PHONY: token-ui
token-ui: guard               ## token de acesso do Headlamp (http://k8s.localtest.me:8080)
	@kubectl create token headlamp -n $(NS) --duration=24h

## ── imagens dos nossos componentes ──────────────────────────────────────────
## Não precisam da guarda: `docker push` fala com o registry, não com o cluster.

images: image-core image-api ## constrói e publica dop-core e dop-api no registry

image-devbox:                 ## imagem do sandbox onde o agente trabalha
	docker build -t $(REGISTRY)/dop/devbox:$(DEVBOX_TAG) $(CURDIR)/images/devbox
	docker push $(REGISTRY)/dop/devbox:$(DEVBOX_TAG)

image-core:                   ## constrói e publica a imagem do core
	docker build -t $(REGISTRY)/dop/dop-core:$(CORE_TAG) \
	  --build-arg VERSION=$(CORE_TAG) $(REPOS)dop-core
	docker push $(REGISTRY)/dop/dop-core:$(CORE_TAG)

image-api:                    ## constrói e publica a imagem do BFF
	docker build -t $(REGISTRY)/dop/dop-api:$(API_TAG) \
	  --build-arg VERSION=$(API_TAG) $(REPOS)dop-api
	docker push $(REGISTRY)/dop/dop-api:$(API_TAG)

rollout: guard                ## espera os nossos Deployments ficarem prontos
	@for d in dop-core-serve dop-core-worker dop-core-sched dop-api; do \
	  kubectl rollout status -n $(NS) deploy/$$d --timeout=120s; \
	done

cluster-up:                   ## cria o cluster k3d do zero
	k3d cluster create $(CLUSTER) \
	  --servers 1 --agents 0 \
	  --port "8080:80@loadbalancer" --port "8443:443@loadbalancer" \
	  --registry-create dop-registry:0.0.0.0:5111 \
	  --k3s-arg "--disable=metrics-server@server:0" \
	  --wait

cluster-stop:                 ## para o cluster, preservando dados
	k3d cluster stop $(CLUSTER)

cluster-rm:                   ## destrói o cluster e os volumes
	k3d cluster delete $(CLUSTER)
