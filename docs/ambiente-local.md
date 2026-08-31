# Ambiente local — notas de operação

## Ciclo de vida

```bash
make cluster-up          # cria do zero
make images              # constrói e publica as imagens dos nossos componentes
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

## Imagens dos nossos componentes

Duas imagens próprias, construídas dos repositórios irmãos e publicadas no
registry do k3d:

| Imagem | Fonte | Modos |
|---|---|---|
| `dop/dop-core` | `../dop-core/Dockerfile` (Go, multi-stage, binário estático) | `serve`, `worker`, `sched` (e `launcher`, ainda não implantado) |
| `dop/dop-api` | `../dop-api/Dockerfile` (Python 3.13 + uv, multi-stage) | — |

```bash
make images              # as duas
make image-core          # só o core
make rollout             # espera os Deployments ficarem prontos
```

`localhost:5111` é o registry visto **de fora** (o `docker push`);
`dop-registry:5000` é o mesmo registry visto **de dentro** (o `image:` do
manifesto). São nomes do mesmo serviço — trocar um pelo outro é `ErrImagePull`.

**Tag versionada, sempre.** `CORE_TAG`/`API_TAG` no `Makefile` e a `image:` do
Deployment sobem juntas. Ver armadilha 5 abaixo.

Ambas rodam como **usuário arbitrário não-root** (requisito OKD/OpenShift): a
permissão vive no grupo 0, nunca num usuário nomeado — o OKD atribui um UID que
não existe em `/etc/passwd`.

## Consumo medido (2026-08-31, ambiente completo)

| | |
|---|---|
| k3d server (Postgres + NATS + Firebase + dop-core ×3 + dop-api) | ~1220 MB |
| load balancer | ~10 MB |
| registry | ~12 MB |
| **total** | **~1,24 GB** |

Antes dos nossos componentes o server ficava em ~935 MB: os três modos do core
somam ~40 MB (Go estático) e o BFF ~90 MB (Python).

O emulador é o componente mais pesado (~300 MB — é Java). `k3d cluster stop dop-local`
devolve tudo à máquina preservando os dados.

`metrics-server` está desabilitado para economizar ~50 MB; por isso `kubectl top` não
funciona. Reativar removendo `--disable=metrics-server` na criação do cluster.

## Acesso a partir do host

```bash
kubectl port-forward -n dop-local svc/postgres 5432:5432
kubectl port-forward -n dop-local svc/nats 4222:4222 8222:8222
kubectl port-forward -n dop-local svc/dop-api 8000:8000
kubectl port-forward -n dop-local svc/dop-core 9090:9090
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

# o BFF responde (a rota é @public — sonda não carrega token)
kubectl run curl --rm -i --restart=Never -n dop-local --image=curlimages/curl:8.11.1 \
  -- -sS http://dop-api.dop-local.svc:8000/healthz

# a superfície gRPC do core, pela reflexão
kubectl port-forward -n dop-local svc/dop-core 9090:9090 &
grpcurl -plaintext localhost:9090 list
grpcurl -plaintext localhost:9090 grpc.health.v1.Health/Check

# o RBAC do core é MESMO mínimo
kubectl auth can-i create secrets -n dop-local \
  --as=system:serviceaccount:dop-local:dop-core     # yes
kubectl auth can-i create secrets -n kube-system \
  --as=system:serviceaccount:dop-local:dop-core     # no
```

## Endereços internos (como os componentes se falam)

| Serviço | Endereço |
|---|---|
| dop-core (gRPC) | `dop-core.dop-local.svc:9090` · health `:9091` |
| dop-api (BFF) | `dop-api.dop-local.svc:8000` |
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

## Armadilhas resolvidas ao subir dop-core e dop-api

1. **A CA do cluster não está no bundle público.** O `SecretStore` do core fala com
   `https://kubernetes.default.svc`, cujo certificado é assinado pela CA **do
   cluster** — que não existe no `ca-certificates` da imagem. O sintoma é cruel:
   o pod fica `Running` e `1/1` (nada no boot toca a API) e a falha só aparece na
   PRIMEIRA credencial que alguém tenta salvar, como
   `x509: certificate signed by unknown authority`.
   **Resolvido no adaptador, não no manifesto.** `secretstore.NewK8s` monta um
   `http.Client` que confia na CA de
   `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` **além** das públicas —
   o pod já recebe esse arquivo do kubelet, sem volume nenhum. Fora do cluster o
   arquivo não existe e o pool do sistema continua valendo, então o TLS com
   Firebase/GCS não muda.
   Saber que o apiserver usa a CA do cluster é conhecimento **do adaptador**: por
   isso `wire.go` não passa mais `Client` — passava um `http.Client` cru, que
   anulava silenciosamente o padrão do adaptador. O campo `K8sConfig.Client`
   permanece só para injeção em teste.
   Verificado sem contorno algum no Deployment: `SetCredential` grava o Secret e
   `kubectl get secret` devolve o valor.
2. **`httpGet` não fala gRPC.** A probe do `serve` aponta para a `:9091` (HTTP), não
   para a `:9090`: contra a porta gRPC a sonda recebe erro de protocolo e o pod
   nunca fica pronto. Todo modo do core expõe `/healthz` na `:9091` — inclusive
   `worker` e `sched`, que não têm porta gRPC nenhuma.
3. **O Service do core seleciona `mode: serve`.** Um seletor só por `app: dop-core`
   mandaria chamada para `worker` e `sched`, que não escutam na 9090 — e o sintoma
   seria intermitente, o pior tipo.
4. **O uvicorn tem logger próprio.** Sem `--log-level warning` ele escreve as
   linhas dele em texto puro no meio do JSON do `structlog`, e o log agregado
   deixa de ser parseável. `PYTHONUNBUFFERED=1` pelo mesmo motivo: sem isso o JSON
   fica preso no buffer e o `kubectl logs` mostra o pod mudo.
5. **`sched` é `Recreate`.** Com `RollingUpdate` o pod novo sobe antes do velho
   morrer e por alguns segundos existem DOIS schedulers disparando a mesma tarefa.

## Estado

Ambiente **completo e testado**: Postgres+pgvector, NATS JetStream, emuladores
Firebase (Auth + Storage), os três modos do `dop-core` e o `dop-api`. Persistência
verificada por restart; log JSON verificado nas duas pontas; `serve` conectado a
Postgres e NATS e respondendo `SERVING` no health gRPC. `make ui` abre o k9s.

Falta implantar o modo **`launcher`** do core — depende do cluster de execução,
que ainda não existe no ambiente local.
