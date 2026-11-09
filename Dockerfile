# ===========================================================================
# Minecraft Java Edition server image - built from scratch, no pre-built
# Minecraft image is used anywhere in this file.
#
# Stage 1 "downloader" fetches the official server.jar from Mojang and
# verifies it. Stage 2 "runtime" is the image that actually ships: it only
# contains a Java runtime, the verified server.jar and the entrypoint, so
# curl and jq never end up in the final image.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: download and verify the official server application
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS downloader

# Minecraft version to build. Override it per build, see README.md -> Usage.
ARG MINECRAFT_VERSION=26.3

# Entry point of Mojang's official version metadata, which is what
# https://www.minecraft.net/en-us/download/server links to internally.
ARG MOJANG_MANIFEST_URL=https://piston-meta.mojang.com/mc/game/version_manifest_v2.json

# Tools needed for the download; they stay in this stage only.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        jq \
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

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

# Java major version installed below. Minecraft 26.3 requires Java 25.
ARG JAVA_MAJOR_VERSION=25

# Fixed paths and the unprivileged account the server runs under.
ENV SERVER_HOME="/opt/minecraft" \
    DATA_DIR="/data" \
    SERVER_USER="minecraft" \
    SERVER_GROUP="minecraft"

# ---------------------------------------------------------------------------
# Default values for every runtime setting, so the container always starts
# even when docker-compose.yaml or the .env file provide nothing at all.
# docker-compose.yaml overrides the non-critical ones.
# ---------------------------------------------------------------------------
ENV EULA="true" \
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
