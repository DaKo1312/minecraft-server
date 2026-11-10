#!/usr/bin/env bash
# ===========================================================================
# Entrypoint of the Minecraft server container.
#
# What it does, in order:
#   1. Refuse to start unless the operator has accepted the Minecraft EULA.
#   2. Tell the Fabric mod loader which server application to start.
#   3. Write the settings that come from environment variables into
#      /data/server.properties. Keys that are NOT managed here are left
#      untouched, so manual edits and the world survive every restart.
#   4. Enable RCON only when a password was supplied via the .env file.
#   5. Hand ownership of the data directory to the unprivileged account and
#      start the server as that account.
#
# The server replaces this script via "exec", so it becomes PID 1 and
# receives SIGTERM directly on "docker compose stop". That is what lets
# Minecraft save the world before the container exits.
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Fallback defaults. The Dockerfile already sets all of these; repeating them
# here means the script also works when the image is run with an empty
# environment.
# ---------------------------------------------------------------------------
SERVER_HOME="${SERVER_HOME:-/opt/minecraft}"
DATA_DIR="${DATA_DIR:-/data}"
SERVER_USER="${SERVER_USER:-minecraft}"
SERVER_GROUP="${SERVER_GROUP:-minecraft}"

EULA="${EULA:-false}"
JAVA_MEMORY="${JAVA_MEMORY:-2G}"
JAVA_OPTS="${JAVA_OPTS:-}"
SERVER_PORT="${SERVER_PORT:-25565}"
MOTD="${MOTD:-Minecraft Server (Docker)}"
DIFFICULTY="${DIFFICULTY:-normal}"
GAMEMODE="${GAMEMODE:-survival}"
LEVEL_NAME="${LEVEL_NAME:-world}"
LEVEL_SEED="${LEVEL_SEED:-}"
MAX_PLAYERS="${MAX_PLAYERS:-10}"
VIEW_DISTANCE="${VIEW_DISTANCE:-10}"
SIMULATION_DISTANCE="${SIMULATION_DISTANCE:-10}"
SPAWN_PROTECTION="${SPAWN_PROTECTION:-16}"
ONLINE_MODE="${ONLINE_MODE:-true}"
PVP="${PVP:-true}"
WHITE_LIST="${WHITE_LIST:-false}"
ENABLE_COMMAND_BLOCK="${ENABLE_COMMAND_BLOCK:-false}"
RCON_PORT="${RCON_PORT:-25575}"
RCON_PASSWORD="${RCON_PASSWORD:-}"

SERVER_JAR="${SERVER_HOME}/server.jar"
LAUNCH_JAR="${SERVER_HOME}/fabric-server-launch.jar"
MODS_DIR="${SERVER_HOME}/mods"
PROPERTIES_FILE="${DATA_DIR}/server.properties"
LAUNCHER_PROPERTIES_FILE="${DATA_DIR}/fabric-server-launcher.properties"
EULA_FILE="${DATA_DIR}/eula.txt"

log() {
    printf '[entrypoint] %s\n' "${1}"
}

# ---------------------------------------------------------------------------
# set_property KEY VALUE
#
# Sets "KEY=VALUE" in server.properties. An existing line for that key is
# replaced, every other line is copied through unchanged. Running this twice
# with the same value changes nothing, so restarts are idempotent.
# ---------------------------------------------------------------------------
set_property() {
    local PROPERTY_KEY="${1}"
    local PROPERTY_VALUE="${2}"
    local TEMP_FILE

    TEMP_FILE="$( mktemp "${PROPERTIES_FILE}.XXXXXX" )"

    if [ -f "${PROPERTIES_FILE}" ]; then
        grep --invert-match --extended-regexp \
            "^[[:space:]]*${PROPERTY_KEY}[[:space:]]*=" \
            "${PROPERTIES_FILE}" > "${TEMP_FILE}" || true
    fi

    printf '%s=%s\n' "${PROPERTY_KEY}" "${PROPERTY_VALUE}" >> "${TEMP_FILE}"
    mv --force "${TEMP_FILE}" "${PROPERTIES_FILE}"
}

# ---------------------------------------------------------------------------
# Sanity check: without the server application and the mod loader there is
# nothing to start.
# ---------------------------------------------------------------------------
if [ ! -f "${SERVER_JAR}" ]; then
    log "ERROR: server application not found at ${SERVER_JAR}"
    exit 1
fi

if [ ! -f "${LAUNCH_JAR}" ]; then
    log "ERROR: Fabric launch jar not found at ${LAUNCH_JAR}"
    exit 1
fi

cd "${DATA_DIR}"

# ---------------------------------------------------------------------------
# 1. EULA
#
# Accepting the agreement is the operator's decision, not the image's, so the
# server does not start until EULA is set to "true" from the outside.
# ---------------------------------------------------------------------------
if [ "${EULA}" != "true" ]; then
    log "ERROR: the Minecraft EULA has not been accepted, refusing to start."
    log "       Read https://www.minecraft.net/eula and, if you agree, set"
    log "       EULA=true in the .env file next to docker-compose.yaml."
    exit 1
fi

log "Minecraft EULA accepted (EULA=${EULA})"
printf 'eula=true\n' > "${EULA_FILE}"

# ---------------------------------------------------------------------------
# 2. Fabric
#
# The loader reads fabric-server-launcher.properties from the working
# directory to find the server application it should start. Pointing it at the
# verified Mojang server.jar is what keeps the official download in use and
# stops the loader from fetching its own copy.
#
# The mods are loaded straight out of the image instead of from the volume, so
# the image alone decides which mods run and no stale jar can survive in
# /data after it was removed from mods.txt.
# ---------------------------------------------------------------------------
log "Fabric loader will start the server application at ${SERVER_JAR}"
printf 'serverJar=%s\n' "${SERVER_JAR}" > "${LAUNCHER_PROPERTIES_FILE}"

if [ -d "${MODS_DIR}" ]; then
    log "Mods from ${MODS_DIR}:"
    for MOD_PATH in "${MODS_DIR}"/*.jar; do
        [ -f "${MOD_PATH}" ] || continue
        log "  - $( basename "${MOD_PATH}" )"
    done
else
    log "No mods directory at ${MODS_DIR}, starting without mods"
fi

# ---------------------------------------------------------------------------
# 3. Managed settings from environment variables
# ---------------------------------------------------------------------------
if [ -f "${PROPERTIES_FILE}" ]; then
    log "Updating managed keys in ${PROPERTIES_FILE} (other keys are kept)"
else
    log "Creating ${PROPERTIES_FILE} from the current environment"
fi

set_property 'server-port'           "${SERVER_PORT}"
set_property 'motd'                  "${MOTD}"
set_property 'difficulty'            "${DIFFICULTY}"
set_property 'gamemode'              "${GAMEMODE}"
set_property 'level-name'            "${LEVEL_NAME}"
set_property 'level-seed'            "${LEVEL_SEED}"
set_property 'max-players'           "${MAX_PLAYERS}"
set_property 'view-distance'         "${VIEW_DISTANCE}"
set_property 'simulation-distance'   "${SIMULATION_DISTANCE}"
set_property 'spawn-protection'      "${SPAWN_PROTECTION}"
set_property 'online-mode'           "${ONLINE_MODE}"
set_property 'pvp'                   "${PVP}"
set_property 'white-list'            "${WHITE_LIST}"
set_property 'enable-command-block'  "${ENABLE_COMMAND_BLOCK}"

# ---------------------------------------------------------------------------
# 4. RCON - only switched on when a password was provided through .env
# ---------------------------------------------------------------------------
if [ -n "${RCON_PASSWORD}" ]; then
    log "RCON enabled on container-internal port ${RCON_PORT}"
    set_property 'enable-rcon'   'true'
    set_property 'rcon.port'     "${RCON_PORT}"
    set_property 'rcon.password' "${RCON_PASSWORD}"
else
    log "RCON disabled (no RCON_PASSWORD set)"
    set_property 'enable-rcon'   'false'
    set_property 'rcon.password' ''
fi

# ---------------------------------------------------------------------------
# 5. Start the server
# ---------------------------------------------------------------------------
JAVA_OPTS_ARRAY=()
if [ -n "${JAVA_OPTS}" ]; then
    read -r -a JAVA_OPTS_ARRAY <<< "${JAVA_OPTS}"
fi

log "Starting Minecraft server (heap: ${JAVA_MEMORY}, port: ${SERVER_PORT})"

if [ "$( id --user )" -eq 0 ]; then
    # Started as root (the normal case): make the mounted volume writable for
    # the service account, then drop all root privileges before exec'ing Java.
    chown --recursive "${SERVER_USER}:${SERVER_GROUP}" "${DATA_DIR}"

    exec setpriv \
        --reuid "${SERVER_USER}" \
        --regid "${SERVER_GROUP}" \
        --init-groups \
        java \
            -Xms"${JAVA_MEMORY}" \
            -Xmx"${JAVA_MEMORY}" \
            -Dfabric.addMods="${MODS_DIR}" \
            "${JAVA_OPTS_ARRAY[@]}" \
            -jar "${LAUNCH_JAR}" \
            --nogui
fi

# Already running as a non-root user (e.g. "user:" set in compose):
# no ownership changes and no privilege drop are possible or needed.
log "Running as UID $( id --user ), skipping privilege drop"
exec java \
    -Xms"${JAVA_MEMORY}" \
    -Xmx"${JAVA_MEMORY}" \
    -Dfabric.addMods="${MODS_DIR}" \
    "${JAVA_OPTS_ARRAY[@]}" \
    -jar "${LAUNCH_JAR}" \
    --nogui
