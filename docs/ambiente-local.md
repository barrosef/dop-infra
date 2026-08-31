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

## Consumo medido (2026-08-31, ambiente completo)

| | |
|---|---|
| k3d server (Postgres + NATS + emuladores Firebase) | ~935 MB |
| load balancer | ~10 MB |
| registry | ~13 MB |
| **total** | **~958 MB** |

O emulador é o componente mais pesado (~300 MB — é Java). `k3d cluster stop dop-local`
devolve tudo à máquina preservando os dados.

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

# emuladores ativos (hub)
kubectl exec -n dop-local firebase-0 -- wget -qO- http://localhost:4400/emulators

# dados persistidos do emulador
kubectl exec -n dop-local firebase-0 -- ls /emulator-data/saved
```

## Endereços internos (como os componentes se falam)

| Serviço | Endereço |
|---|---|
| Postgres | `postgres.dop-local.svc:5432` |
| NATS | `nats.dop-local.svc:4222` · monitor `:8222` |
| Firebase Auth | `firebase.dop-local.svc:9099` |
| Firebase Storage | `firebase.dop-local.svc:9199` |
| Emulator Hub / UI | `firebase.dop-local.svc:4400` / `:4000` |

## Armadilhas resolvidas na construção dos emuladores

Registradas porque custaram tempo e voltariam a custar:

1. **`HOME` gravável** — o `firebase-tools` escreve config e cache; rodando como usuário
   arbitrário sem `HOME` próprio, o start morre com "update check failed / unexpected
   error", mensagem que **não indica a causa real**.
2. **JARs baixados na build** — `firebase setup:emulators:storage` e `:ui` no Dockerfile.
   Sem isso o pod tenta baixar 52 MB no primeiro boot e falha quando a rede oscila.
3. **JDK 21** — o `firebase-tools` 14 avisa e o 15 exigirá.
4. **A UI só sobe se algum emulador tiver UI.** Com `--only auth,storage` e a probe
   apontando para a porta 4000, o pod nunca fica pronto. **A probe checa o hub (4400)**,
   que existe sempre.
5. **Tag de imagem versionada** (`14.24.0-2`) — reconstruir com a mesma tag não garante
   que o pod puxe a nova camada.

## Estado

Ambiente **completo e testado**: Postgres+pgvector, NATS JetStream e emuladores Firebase
(Auth + Storage), com persistência verificada por restart. `make ui` abre o k9s.
