# There is no official image of the Firebase Emulator Suite.
# We build our own with PINNED versions — consistent with the project's supply
# chain stance (ADR-0020).
FROM node:22-alpine

ARG FIREBASE_TOOLS_VERSION=14.24.0
# JDK 21: firebase-tools 15 will require >= 21, and 14 already warns about it.
RUN apk add --no-cache openjdk21-jre-headless bash curl \
 && npm install -g firebase-tools@${FIREBASE_TOOLS_VERSION} \
 && npm cache clean --force

# A writable HOME: the CLI writes config and a JAR cache; without it the start
# dies with "update check failed / unexpected error" while downloading the rules
# runtime.
ENV HOME=/home/emulator \
    XDG_CONFIG_HOME=/home/emulator/.config \
    XDG_CACHE_HOME=/home/emulator/.cache

# It downloads the emulator's JARs AT BUILD TIME — an offline, predictable start
# that does not depend on the network at the pod's first boot.
RUN mkdir -p /home/emulator /app /emulator-data \
 && cd /app \
 && printf '{"emulators":{"auth":{"port":9099},"storage":{"port":9199},"ui":{"enabled":false}},"storage":{"rules":"storage.rules"}}\n' > firebase.json \
 && printf 'rules_version = "2";\nservice firebase.storage {\n match /b/{b}/o { match /{p=**} { allow read, write: if true; } }\n}\n' > storage.rules \
 && firebase setup:emulators:storage \
 && firebase setup:emulators:ui \
 && rm -f /app/firebase.json /app/storage.rules

# An arbitrary non-root user (an OKD/OpenShift requirement — the substrate spec
# §2): the root group with write access to the directories the process uses.
RUN chgrp -R 0 /app /emulator-data /home/emulator \
 && chmod -R g=u /app /emulator-data /home/emulator

WORKDIR /app
USER 1001
EXPOSE 4000 9099 9199
