# dop-infra

Infraestrutura da plataforma DOP: Terraform (QA/stage/prod) e ambiente local em k3d.

> **Estado:** ambiente local funcional; Terraform em estrutura, sem resources.
> Spec: `docs/superpowers/specs/dop-infra.md` no meta-repositório.

## Ambiente local

```bash
make cluster-up     # cria o cluster k3d
make up             # aplica o ambiente
make status         # pods, PVCs e services
```

**Tudo é declarativo.** Não há script de orquestração: persistência é PVC, espera é
`readinessProbe`, encerramento gracioso é `terminationGracePeriodSeconds`, reset é
`kubectl delete pvc`. O `Makefile` existe por **uma** razão — a guarda de contexto — e
oferece atalhos por conveniência. Operação normal é `kubectl`, `k3d` e **k9s** direto.

**Guarda de contexto.** Todo alvo que fala com cluster recusa executar se o contexto
ativo não for `k3d-dop-local`. Esta máquina tem contextos de produção de clientes no
kubeconfig — a guarda não é conveniência.

| Alvo | |
|---|---|
| `make up` / `down` | aplica / remove o namespace |
| `make reset` | apaga os PVCs (dados) sem destruir o cluster |
| `make status` | pods, PVCs, services |
| `make logs C=postgres` | logs de um componente |
| `make cluster-up` / `cluster-stop` / `cluster-rm` | ciclo de vida do cluster |

| Componente | Endereço interno | Host |
|---|---|---|
| PostgreSQL 17 + pgvector | `postgres.dop-local.svc:5432` | `kubectl port-forward` |
| NATS JetStream | `nats.dop-local.svc:4222` · monitor `:8222` | idem |
| Ingress (Traefik) | — | `localhost:8080` / `:8443` |
| Registry de imagens | `dop-registry:5000` | `localhost:5111` |

Credencial do Postgres local: `dop` / `dop-local-dev` / base `dop` — **desenvolvimento
apenas**; em QA/stage/prod a credencial vem do `SecretStore` (ADR-0001), nunca de
manifesto.

## Propriedade de recursos — quem é dono do quê

Regra da [ADR-0020](../../docs/adr/0020-emuladores-firebase-e-dono-unico.md): recurso
criado pelo console fica fora do state e é revertido no `apply` seguinte. **Nada é criado
pelo console.**

| Recurso | Dono | Onde vive |
|---|---|---|
| Projetos GCP, IAM, APIs habilitadas | **Terraform** | `terraform/bootstrap` |
| Cloud Run, GKE, Cloud SQL, buckets, Secret Manager | **Terraform** | `terraform/stacks/platform` |
| Regras de Storage e índices do Firebase | **arquivos versionados** (`firebase.json`, rules) | publicados pela CLI; Terraform referencia, não recria |
| Provedores de autenticação do Firebase | **Terraform** | declarado explicitamente; nunca alterado no console |
| Manifestos do ambiente local | **Kustomize** | `k3s/` |

## Estrutura

```
terraform/
├── bootstrap/          projetos, bucket de estado, SAs do CI — aplicado uma vez
├── modules/            blocos reutilizáveis, sem valor de ambiente
└── stacks/platform/    ÚNICO root module + envs/{qa,stage,prod}.tfvars
k3s/
├── base/               namespace
├── services/           postgres · nats
├── emulators/          firebase (auth + storage)
└── overlays/local/     composição do ambiente local
```
