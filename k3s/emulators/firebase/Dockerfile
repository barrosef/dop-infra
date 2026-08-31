# Não existe imagem oficial do Firebase Emulator Suite.
# Construímos a nossa com versões FIXADAS — coerente com a postura de cadeia
# de suprimentos do projeto (ADR-0020).
FROM node:22-alpine

ARG FIREBASE_TOOLS_VERSION=14.24.0
# JDK 21: o firebase-tools 15 exigirá >= 21, e o 14 já avisa.
RUN apk add --no-cache openjdk21-jre-headless bash curl \
 && npm install -g firebase-tools@${FIREBASE_TOOLS_VERSION} \
 && npm cache clean --force

# HOME gravável: o CLI escreve config e cache de JARs; sem isso o start morre
# com "update check failed / unexpected error" ao baixar o runtime de regras.
ENV HOME=/home/emulator \
    XDG_CONFIG_HOME=/home/emulator/.config \
    XDG_CACHE_HOME=/home/emulator/.cache

# Baixa os JARs do emulador NA BUILD — start offline, previsível e sem
# depender de rede no primeiro boot do pod.
RUN mkdir -p /home/emulator /app /emulator-data \
 && cd /app \
 && printf '{"emulators":{"auth":{"port":9099},"storage":{"port":9199},"ui":{"enabled":false}},"storage":{"rules":"storage.rules"}}\n' > firebase.json \
 && printf 'rules_version = "2";\nservice firebase.storage {\n match /b/{b}/o { match /{p=**} { allow read, write: if true; } }\n}\n' > storage.rules \
 && firebase setup:emulators:storage \
 && firebase setup:emulators:ui \
 && rm -f /app/firebase.json /app/storage.rules

# Usuário arbitrário não-root (requisito OKD/OpenShift — spec do substrato §2):
# grupo root com escrita nos diretórios que o processo usa.
RUN chgrp -R 0 /app /emulator-data /home/emulator \
 && chmod -R g=u /app /emulator-data /home/emulator

WORKDIR /app
USER 1001
EXPOSE 4000 9099 9199
