# Ambiente local — notas de operação

## Ciclo de vida

```bash
make cluster-up          # cria do zero
make up                  # aplica o ambiente
make cluster-stop        # para, libera memória, preserva dados
k3d cluster start dop-local
make reset               # apaga os dados (PVCs), mantém o cluster
make cluster-rm          # destrói tudo
```

Por que não há `dev.sh`: num ambiente `docker compose` seria preciso script para criar
diretório de dados, importar condicionalmente, aguardar prontidão e resetar volume
root-owned. Em Kubernetes isso é PVC, `if` no `command` do pod, `readinessProbe`,
`terminationGracePeriodSeconds` e `kubectl delete pvc` — tudo declarativo. Sobra a guarda
de contexto, que vive no `Makefile`.

## Consumo medido (2026-08-30, cluster + postgres + nats)

| | |
|---|---|
| k3d server (inclui postgres e nats) | ~643 MB |
| load balancer | ~10 MB |
| registry | ~6 MB |
| **total** | **~660 MB** |

`metrics-server` está desabilitado para economizar ~50 MB; por isso `kubectl top` não
funciona. Reativar removendo `--disable=metrics-server` na criação do cluster.

## Acesso a partir do host

```bash
kubectl port-forward -n dop-local svc/postgres 5432:5432
kubectl port-forward -n dop-local svc/nats 4222:4222 8222:8222
```

## Verificações rápidas

```bash
# extensões do Postgres
kubectl exec -n dop-local postgres-0 -- psql -U dop -d dop -tAc \
  "select extname||' '||extversion from pg_extension order by extname;"

# JetStream ativo
kubectl exec -n dop-local nats-0 -- wget -qO- http://localhost:8222/jsz
```

## Pendências

- Emuladores Firebase (auth :9099, storage :9199) — ADR-0020: `--export-on-exit` +
  `--import` condicional no `command`, PVC para os dados e
  `terminationGracePeriodSeconds: 30`.
- k9s como interface de inspeção.
