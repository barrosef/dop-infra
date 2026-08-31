# A imagem do sandbox onde o agente trabalha.
#
# Duas exigências que parecem detalhe e não são:
#
# 1. **Processo de longa duração.** O sandbox precisa ficar de pé para o agente
#    executar comando nele (`SandboxLauncher.Exec`). Imagem cujo comando padrão
#    termina — `alpine`, por exemplo — faz o contêiner sair no ato, e o exec
#    seguinte falha com "container is not running", que manda procurar no lugar
#    errado.
#
# 2. **Usuário arbitrário NÃO-root.** OKD/OpenShift atribuem um UID aleatório
#    por SCC, e a imagem tem que funcionar com ele. É requisito de IMAGEM, não
#    de implantação — por isso o workspace pertence ao grupo 0 com permissão de
#    escrita, que é como o usuário arbitrário consegue escrever.
FROM alpine:3.22

# TODO: git, bash, curl e ca-certificates entram aqui quando o build tiver
# rede para o índice do apk. Sem eles o agente tem shell e nada mais — dá para
# provar o caminho de execução, não para trabalhar num repositório de verdade.

# O workspace é o que SOBREVIVE à suspensão (garantia 5 da porta), e o exec
# começa aqui (garantia 14).
RUN mkdir -p /workspace \
 && chgrp -R 0 /workspace \
 && chmod -R g=u /workspace
WORKDIR /workspace

USER 1001

# Fica de pé até alguém mandar parar. O trabalho entra por exec.
CMD ["sleep", "infinity"]
