# ===========================================================================
# Minecraft Java Edition server image - built from scratch, no pre-built
# Minecraft image is used anywhere in this file.
#
# Stage 1 "downloader" fetches everything the server needs and verifies each
# download against a published checksum: the official server.jar from Mojang,
# the Fabric mod loader and the mods listed in mods.txt. Stage 2 "runtime" is
# the image that actually ships: it only contains a Java runtime, the verified
# files and the entrypoint, so curl, jq and the installer never end up in the
# final image.
# ===========================================================================

# Java major version to install. Minecraft 26.3 requires Java 25. Declared
# before the first FROM so that both stages can use the same value.
ARG JAVA_MAJOR_VERSION=25

# Minecraft version to build. Override it per build, see README.md -> Usage.
ARG MINECRAFT_VERSION=26.3

# ---------------------------------------------------------------------------
# Stage 1: download and verify the server application, the mod loader and the
# mods
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS downloader

ARG JAVA_MAJOR_VERSION
ARG MINECRAFT_VERSION

# Entry point of Mojang's official version metadata, which is what
# https://www.minecraft.net/en-us/download/server links to internally.
ARG MOJANG_MANIFEST_URL=https://piston-meta.mojang.com/mc/game/version_manifest_v2.json

# Fabric mod loader. The installer is run below to assemble the launch jar and
# the loader libraries; it is pinned by version and SHA256 checksum.
ARG FABRIC_MAVEN_URL=https://maven.fabricmc.net
ARG FABRIC_LOADER_VERSION=0.20.1
ARG FABRIC_INSTALLER_VERSION=1.1.2
ARG FABRIC_INSTALLER_SHA256=61e035bf7bf70153e127440ce34de47c9036f0a2d0c65d1529454bd35ceefe4f

# Tools needed for the downloads and for running the Fabric installer; they
# stay in this stage only.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        "openjdk-${JAVA_MAJOR_VERSION}-jre-headless" \
    && rm --recursive --force /var/lib/apt/lists/*

WORKDIR /download

# Resolve the version metadata, download server.jar and verify it against the
# SHA1 checksum published by Mojang. The build fails if the checksum differs.
#
# MINECRAFT_VERSION is exported so that jq can read it via "env.MINECRAFT_VERSION".
# That avoids jq-internal variables and keeps the ${...} notation everywhere.
RUN set -eux; \
    export MINECRAFT_VERSION="${MINECRAFT_VERSION}"; \
    curl --fail --silent --show-error --location "${MOJANG_MANIFEST_URL}" \
        --output version_manifest.json; \
    VERSION_METADATA_URL="$( jq --exit-status --raw-output \
        '.versions[] | select(.id == env.MINECRAFT_VERSION) | .url' \
        version_manifest.json )"; \
    curl --fail --silent --show-error --location "${VERSION_METADATA_URL}" \
        --output version.json; \
    SERVER_JAR_URL="$( jq --exit-status --raw-output '.downloads.server.url' version.json )"; \
    SERVER_JAR_SHA1="$( jq --exit-status --raw-output '.downloads.server.sha1' version.json )"; \
    REQUIRED_JAVA_VERSION="$( jq --exit-status --raw-output '.javaVersion.majorVersion' version.json )"; \
    echo "Minecraft ${MINECRAFT_VERSION} requires Java ${REQUIRED_JAVA_VERSION}"; \
    curl --fail --silent --show-error --location "${SERVER_JAR_URL}" --output server.jar; \
    echo "${SERVER_JAR_SHA1}  server.jar" | sha1sum --check -

# Fabric mod loader. The installer writes fabric-server-launch.jar plus the
# loader libraries into /download/fabric. It does not replace server.jar: the
# launch jar starts the verified Mojang application and loads the mods into
# it, so the server application still comes from the official download.
RUN set -eux; \
    curl --fail --silent --show-error --location \
        "${FABRIC_MAVEN_URL}/net/fabricmc/fabric-installer/${FABRIC_INSTALLER_VERSION}/fabric-installer-${FABRIC_INSTALLER_VERSION}.jar" \
        --output fabric-installer.jar; \
    echo "${FABRIC_INSTALLER_SHA256}  fabric-installer.jar" | sha256sum --check -; \
    mkdir --parents /download/fabric; \
    java -jar fabric-installer.jar server \
        -mcversion "${MINECRAFT_VERSION}" \
        -loader "${FABRIC_LOADER_VERSION}" \
        -dir /download/fabric; \
    test -f /download/fabric/fabric-server-launch.jar

# Mods, pinned and checksummed in mods.txt. Each entry is
# "<SHA512>  <file name>  <URL>"; comments and blank lines are skipped.
COPY mods.txt /download/mods.txt
RUN set -eux; \
    mkdir --parents /download/mods; \
    cd /download/mods; \
    grep --invert-match --extended-regexp '^[[:space:]]*(#|$)' /download/mods.txt \
    | while read -r MOD_SHA512 MOD_FILE MOD_URL; do \
        echo "Downloading ${MOD_FILE}"; \
        curl --fail --silent --show-error --location "${MOD_URL}" --output "${MOD_FILE}"; \
        echo "${MOD_SHA512}  ${MOD_FILE}" | sha512sum --check -; \
    done; \
    MOD_COUNT="$( find /download/mods -name '*.jar' | wc --lines )"; \
    echo "Installed ${MOD_COUNT} mods"; \
    test "${MOD_COUNT}" -gt 0

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

ARG JAVA_MAJOR_VERSION

# Fixed paths and the unprivileged account the server runs under.
ENV SERVER_HOME="/opt/minecraft" \
    DATA_DIR="/data" \
    SERVER_USER="minecraft" \
    SERVER_GROUP="minecraft"

# ---------------------------------------------------------------------------
# Default values for every runtime setting, so the container needs no
# configuration at all - except for the one decision the image must not make
# on behalf of whoever runs it. EULA therefore defaults to "false" and
# entrypoint.sh refuses to start the server until it is set to "true".
# docker-compose.yaml overrides the non-critical values.
# ---------------------------------------------------------------------------
ENV EULA="false" \
    JAVA_MEMORY="2G" \
    JAVA_OPTS="" \
    SERVER_PORT="25565" \
    MOTD="Minecraft Server (Docker)" \
    DIFFICULTY="normal" \
    GAMEMODE="survival" \
    LEVEL_NAME="world" \
    LEVEL_SEED="" \
    MAX_PLAYERS="10" \
    VIEW_DISTANCE="10" \
    SIMULATION_DISTANCE="10" \
    SPAWN_PROTECTION="16" \
    ONLINE_MODE="true" \
    PVP="true" \
    WHITE_LIST="false" \
    ENABLE_COMMAND_BLOCK="false" \
    RCON_PORT="25575" \
    RCON_PASSWORD=""

# Headless Java runtime. "setpriv" (used by the entrypoint to drop root) is
# part of util-linux and already present in the base image.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        "openjdk-${JAVA_MAJOR_VERSION}-jre-headless" \
    && rm --recursive --force /var/lib/apt/lists/*

# Dedicated system account; the server must not run as root.
RUN groupadd --system "${SERVER_GROUP}" \
    && useradd --system \
        --gid "${SERVER_GROUP}" \
        --home-dir "${DATA_DIR}" \
        --shell /usr/sbin/nologin \
        "${SERVER_USER}" \
    && mkdir --parents "${SERVER_HOME}" "${DATA_DIR}" \
    && chown "${SERVER_USER}:${SERVER_GROUP}" "${DATA_DIR}"

# Verified server application from stage 1.
COPY --from=downloader /download/server.jar "${SERVER_HOME}/server.jar"

# Fabric mod loader. The relative class path inside fabric-server-launch.jar
# resolves next to the jar itself, so "libraries" has to stay beside it.
COPY --from=downloader /download/fabric/fabric-server-launch.jar "${SERVER_HOME}/fabric-server-launch.jar"
COPY --from=downloader /download/fabric/libraries "${SERVER_HOME}/libraries"

# Verified mods. They live in the image rather than in the volume, so the
# image alone decides which mods run.
COPY --from=downloader /download/mods "${SERVER_HOME}/mods"

# Entrypoint. The sed call strips Windows line endings (CRLF), which would
# otherwise make the script unusable when the repository is cloned on Windows.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed --in-place 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

# World, configuration and logs live here and are mounted as a volume.
VOLUME ["/data"]
WORKDIR /data

# Minecraft's default port inside the container. docker-compose.yaml maps the
# public host port onto it.
EXPOSE 25565/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
