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
kubectl port-forward -n dop-local svc/secretmanager 8085:9090   # gRPC do Secret Manager
```

A suíte de contrato do `SecretStore` procura o emulador em `127.0.0.1:8085`
(gRPC) — é por isso que o port-forward acima usa essa porta. Outra qualquer,
com `SECRET_MANAGER_EMULATOR_HOST` apontando para ela.

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
| Secret Manager (gRPC) | `secretmanager.dop-local.svc:9090` |
| Secret Manager (REST, depuração) | `secretmanager.dop-local.svc:8080` |

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

## Limites conhecidos do emulador de Storage

Descobertos rodando a suíte de contrato do `ObjectStore` contra ele. Nenhum é
defeito do nosso adaptador: o adaptador de sistema de arquivos passa nos 13
subtestes, e o GCS de verdade aceita os dois casos abaixo.

1. **Pendura com `Content-Type: application/json`.** Com `uploadType=media` e
   esse tipo EXATO, o emulador nunca responde — a conexão fica aberta até o
   timeout do cliente. Reproduzível com curl, mesmo corpo:

   | Content-Type | Resposta |
   |---|---|
   | `application/json` | **pendura** |
   | `application/json; charset=utf-8` | 400 |
   | `text/plain`, `text/json`, `application/xml`, `application/octet-stream` | 200 |

   Consequência prática: **guardar JSON no object store pendura no ambiente
   local**. Quem precisar disso antes de o emulador corrigir deve gravar com um
   tipo que ele aceite.

2. **Cai sob concorrência.** Cerca de 16 operações simultâneas derrubam o
   processo (sai com código 2 e o pod reinicia — dá para ver o contador de
   restart subir no exato momento). Pelo Ingress o sintoma é 502 do Traefik;
   por port-forward, "connection refused" — dois disfarces da mesma queda.

O alvo `make test-contract-integration` do dop-core exclui esses dois subtestes,
imprimindo o motivo. A alternativa seria deixá-los vermelhos para sempre, e
suíte cronicamente vermelha é suíte que ninguém lê.

**Probes afrouxadas por causa disso.** `timeoutSeconds` era o padrão de 1s, e a
readiness já havia expirado 7 vezes em duas horas de ambiente ocioso: o hub
responde na mesma thread que atende upload. Agora são 5s, e a liveness só
reinicia depois de 3 falhas × 20s — reiniciar por lentidão passageira apaga o
estado de quem estiver usando.

## Emulador do Secret Manager — onde ele MENTE sobre a produção

`k3s/emulators/secretmanager/`, imagem
`ghcr.io/blackwell-systems/gcp-secret-manager-emulator-dual` 1.9.0 (Apache-2.0),
**fixada por digest** e **só para desenvolvimento**. Escrever o nosso é a
pendência **P-17** do ROADMAP.

Existe porque o Google **não publica emulador do Secret Manager** — publica de
Storage, Pub/Sub, Firestore, Bigtable e Spanner, mas não deste. Sem ele o
adaptador `gcp` da porta `SecretStore` só seria exercitável contra um projeto
GCP de verdade, e a regra dos dois adaptadores da ADR-0001 seria letra morta
justamente na porta que guarda credencial.

**Leia esta lista antes de confiar num teste verde.** Cada item foi verificado
contra o emulador rodando, e cada um é um lugar onde o ambiente local é mais
permissivo que o GCP real — o mesmo padrão que já produziu duas falhas graves de
segurança neste projeto (o emulador de Auth não assina token, e por isso a
verificação de assinatura simplesmente não existia). Onde há defesa, ela está em
`dop-core/internal/adapter/secretstore/gcp.go`, que repete esta lista.

| # | O emulador | O GCP real | Defesa no adaptador |
|---|---|---|---|
| 1 | aceita `CreateSecret` **sem** `replication` | a referência REST marca o campo como *Required* (o `.proto`, mais novo, diz *Optional* — discordam entre si) | manda `Replication_Automatic` sempre, explícito |
| 2 | aceita **qualquer** `secretId`: ponto, espaço, barra, maiúscula, 300 caracteres — tudo respondeu 200 | `[A-Za-z0-9_-]`, máximo 255 | valida o nome antes de cada chamada |
| 3 | guardou um valor de **128 KiB** | 64 KiB por versão | recusa acima de 64 KiB antes de sair da máquina |
| 4 | devolve `dataCrc32c` **sempre 0** e ignora o checksum enviado | verifica na escrita e sempre devolve na leitura | manda o CRC; na leitura só confere se vier ≠ 0. A integridade real vem da confirmação do `Put`, que compara os bytes |
| 5 | `latest` **cai para trás**: com a v3 desabilitada e a v2 destruída, serve a **v1** | `latest` é "an alias to the most recently **created** SecretVersion", sem olhar estado — se ela estiver desabilitada/destruída, o acesso **falha** | parcial: pelo desenho, a versão de maior número está sempre habilitada. **Diverge se alguém desabilitar por fora** (console, Terraform) |
| 6 | propagação **0 ms** | eventualmente consistente — ver abaixo | o `Put` espera o `latest` alcançar a versão nova |
| 7 | **sem cota nenhuma** | `AddSecretVersion` 2 qps/120 qpm **por segredo**; destroy/disable 1 qps **por versão**; por projeto 90.000 acessos/min mas só **600 leituras/min e 600 escritas/min** | erro de cota vira `KindUnavailable` (retryável). Nada simula a cota |
| 8 | **sem IAM**: qualquer chamador lê qualquer segredo | IAM é a segunda barreira do isolamento entre contas | NetworkPolicy `secretmanager-somente-core`. Nenhum teste local exercita IAM |
| 9 | apagar e recriar o mesmo nome funciona no ato | `DeleteSecret` é irreversível e imediato, mas os metadados são eventualmente consistentes: recriar em seguida pode dar `AlreadyExists` | nenhuma. A suíte de contrato faz exatamente esse ciclo |
| 10 | **não persiste**: o `/data` da imagem fica vazio, não há flag de import/export e um restart apaga tudo | durável | nenhuma — por isso o manifesto é `Deployment` sem PVC, e não `StatefulSet` como o do Firebase |

**Consequência do item 10:** ao reiniciar o pod do emulador, **toda credencial
gravada no ambiente local some**. Não é bug; é o que este emulador é.

### O caso mais grave: leitura-após-escrita

A porta `SecretStore` promete, na garantia 1, que um `Get` logo depois de um
`Put` devolve o valor gravado. O Google documenta o contrário, em
<https://cloud.google.com/secret-manager/docs/reference/consistency>:

> "adding a secret version and then immediately accessing that secret version
> **by version number** is a strongly consistent operation" — e — "This doesn't
> apply when you access a secret version using aliases or `latest`". "Other
> operations within Secret Manager are eventually consistent", convergindo
> "typically within minutes, but may take a few hours".

O único caminho fortemente consistente exige carregar o **número da versão**, e
`ports.SecretRef` não tem onde guardá-lo — versionamento está fora da porta de
propósito. Ou seja: **no GCP real, um `Get` logo depois de um `Put` pode
legitimamente devolver `(nil, nil)`**, que pela porta significa "não existe". A
credencial recém-gravada apareceria como ausente.

No emulador isso **nunca acontece**, e o subteste
`1_leitura_apos_escrita_imediata` passa em 0,01 s. É o exemplo mais claro de
teste verde que não prova nada.

O que o adaptador faz enquanto isso: confirma a gravação por número (forte,
sempre funciona) e depois **espera o alias `latest` alcançar a versão nova**,
com teto em `SECRET_PROPAGATION_SECONDS` (padrão 30 s). O `Put` não retorna
antes. Se não convergir, devolve `KindUnavailable` dizendo exatamente isso — um
`Put` lento e um erro explícito são melhores que um `Get` silencioso devolvendo
"não existe". **Não é conserto**: é a decisão de arquitetura ficando visível até
alguém tomá-la (ou a porta devolve identificador de versão no `Put`, ou a
garantia 1 muda de redação).

### O que a suíte de contrato NÃO cobre

Descoberto quebrando garantias de propósito e vendo o que passava:

- **`Put` destruir o valor anterior não é verificado.** Removendo a destruição
  das versões antigas, os sete subtestes continuam verdes: o subteste 4 só
  confere que o `Get` devolve o valor novo, e não que o antigo deixou de ser
  legível. No GCP real o valor antigo continuaria acessível por número de
  versão — "rotacionei a credencial vazada" significando coisas diferentes em
  cada adaptador.
- **Isolamento por IAM não é verificado** (item 8 da tabela). O que a suíte
  prova sobre a garantia 5 é só a metade que vive no nome.

## Acesso sem port-forward

Os emuladores também respondem pelo loadbalancer do k3d, via Ingress:

```
http://auth.localtest.me:8080      → emulador de Auth    (9099)
http://storage.localtest.me:8080   → emulador de Storage (9199)
```

`localtest.me` é um domínio público que resolve para 127.0.0.1; sem DNS, use
`curl --resolve` ou o header `Host`. Prefira este caminho ao `kubectl
port-forward`: o port-forward cai sob rajada de conexões, e o teste então falha
por motivo errado — inventando defeito de adaptador onde não há.

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
