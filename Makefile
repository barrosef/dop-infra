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

# TAG VERSIONADA, sempre. Reconstruir com a mesma tag NÃO garante que o pod puxe
# a camada nova: o kubelet vê o mesmo nome e reaproveita o que já tem em cache.
# Ao mudar código: incremente aqui E na `image:` do Deployment correspondente.
CORE_TAG := 0.1.0-4
API_TAG  := 0.1.0-2

.PHONY: guard up down reset status logs ui cluster-up cluster-stop cluster-rm \
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

## ── imagens dos nossos componentes ──────────────────────────────────────────
## Não precisam da guarda: `docker push` fala com o registry, não com o cluster.

images: image-core image-api ## constrói e publica dop-core e dop-api no registry

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
