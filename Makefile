# Makefile mínimo — a única automação é a guarda de contexto.
# Operação normal é kubectl/k3d/k9s direto; aqui só o que precisa de proteção.

CLUSTER  := dop-local
CONTEXT  := k3d-$(CLUSTER)
NS       := dop-local
OVERLAY  := k3s/overlays/local

.PHONY: guard up down reset status logs cluster-up cluster-stop cluster-rm

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

logs: guard                   ## logs de um componente: make logs C=postgres
	kubectl logs -f -n $(NS) sts/$(C)

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
