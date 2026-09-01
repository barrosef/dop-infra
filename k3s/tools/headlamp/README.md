# Headlamp — UI web do cluster

Por que Headlamp e não Rancher: o Rancher é um produto de gestão de FROTA de
clusters e pede ~1 GB só para si — mais do que o ambiente inteiro do DOP
consome hoje (~1,24 GB). Aqui a necessidade é olhar UM cluster de
desenvolvimento. O Headlamp (CNCF) resolve isso em **48 MB** — medido
no k3d em 2026-09-01, não estimado.

O `k9s` (`make ui`) continua sendo o caminho mais rápido no terminal. Os dois
convivem: o k9s é melhor para operar, o Headlamp para ENXERGAR — árvore de
recursos, YAML lado a lado, logs de vários pods, e um link que dá para mandar
para alguém.

Acesso: `http://k8s.localtest.me:8080`, pelo mesmo loadbalancer do k3d que
serve os emuladores — sem port-forward, pelo mesmo motivo documentado em
`emulators/firebase/ingress.yaml`.

O token de entrada sai de `make token-ui`.

## Permissão

O ServiceAccount é `cluster-admin`. Isso é aceitável AQUI e em nenhum outro
lugar: é um cluster k3d descartável, na máquina do desenvolvedor, sem dado de
ninguém. Se este diretório algum dia for parar num overlay que não seja
`local`, a regra precisa virar RBAC de leitura — e é por isso que ele NÃO está
no `base`, e sim referenciado só pelo overlay local.
