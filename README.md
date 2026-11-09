# Minecraft Server on Docker

A self-contained Docker setup that builds and runs a vanilla **Minecraft Java
Edition** server. The image is assembled from a plain Debian base image; no
pre-built Minecraft image is used.

## Table of Contents

- [Description](#description)
- [Repository Contents](#repository-contents)
- [Quickstart](#quickstart)
- [Usage](#usage)
  - [How configuration is applied](#how-configuration-is-applied)
  - [Non-critical configuration](#non-critical-configuration)
  - [Critical configuration via .env](#critical-configuration-via-env)
  - [Changing the published port](#changing-the-published-port)
  - [Changing the Minecraft version](#changing-the-minecraft-version)
  - [Persistence and backups](#persistence-and-backups)
  - [Server console and operator rights](#server-console-and-operator-rights)
  - [Automatic restart after a failure](#automatic-restart-after-a-failure)
  - [Stopping the server safely](#stopping-the-server-safely)
  - [Using RCON](#using-rcon)
- [Testing](#testing)
- [Security Notes](#security-notes)

## Description

This repository contains everything needed to build, configure and operate a
Minecraft Java Edition server in a Docker container on a cloud VM.

The essential contents are a `Dockerfile` that assembles the server image, an
`entrypoint.sh` that turns environment variables into server configuration, a
`docker-compose.yaml` that deploys the image as the `mc-server` service, and a
`check_status.py` script that verifies reachability from the outside.

Its purpose is to make the server reproducible and operable: the same commands
produce the same server on any Docker host, the world survives restarts and
rebuilds, and every setting is changed through configuration rather than by
editing files inside a running container.

How it works:

- **Two-stage build.** The first stage installs `curl` and `jq`, reads the
  official Mojang version metadata, downloads `server.jar` and verifies it
  against the SHA1 checksum published by Mojang. The build fails if the checksum
  does not match. The second stage receives only the verified file, so the
  download tools never ship in the final image.
- **Own base image.** `debian:trixie-slim` plus the headless Java runtime that
  the chosen Minecraft version requires. Minecraft 26.3 requires Java 25.
- **Unprivileged runtime.** The entrypoint prepares the data directory as root
  and then drops all privileges, so the server process itself runs as the
  dedicated system account `minecraft` (UID 999).
- **Configuration from the environment.** `entrypoint.sh` writes `eula.txt` and
  the managed keys of `server.properties` on every start. Keys it does not
  manage are preserved, so manual tuning is not lost.
- **Always startable.** Every variable has a default value in the image, so the
  container starts even with no environment and no `.env` file.
- **Persistent game state.** World, configuration and logs live in a bind mount
  on the host and therefore survive restarts, `docker compose down` and image
  rebuilds.
- **Self-healing.** `restart: unless-stopped` brings the container back after a
  crash and after a host reboot.

Built as the Minecraft server project of the DevSecOps course at Developer
Akademie.

## Repository Contents

| File | Description |
|---|---|
| `Dockerfile` | Two-stage build. Stage 1 downloads and SHA1-verifies the official `server.jar`; stage 2 installs the Java runtime, creates the unprivileged `minecraft` account and defines the default value of every setting. |
| `entrypoint.sh` | Container start script. Accepts the EULA, writes the environment-driven keys into `server.properties`, enables RCON only when a password is present, drops root privileges and executes the server so it becomes PID 1. |
| `docker-compose.yaml` | Deployment of the `mc-server` service: build arguments, published port, non-critical environment, optional `.env`, bind-mounted volume and restart policy. |
| `.env.example` | Tracked template for the untracked `.env` file, which holds the critical configuration (currently the RCON password). |
| `.gitignore` | Keeps runtime data, the real `.env`, Python virtual environments, archives and credential files out of the repository. |
| `.dockerignore` | Keeps the build context small; without it the whole world in `data/` would be uploaded to the Docker daemon on every build. |
| `check_status.py` | Status check via [mcstatus](https://github.com/py-mine/mcstatus). Performs a Server List Ping and prints version, player count, MOTD and latency. |
| `requirements.txt` | Pinned dependency of `check_status.py`. Installed into a local virtual environment, never into the image. |
| `README.md` | This documentation. |

Two directories are created at runtime and are intentionally untracked: `data/`
holds the world, configuration and logs of the server; `.venv/` holds the
virtual environment for `check_status.py`.

## Quickstart

**Requirements**

- A Linux VM with a public IP address
- Docker Engine and Docker Compose **v2.24 or newer** (`docker compose version`)
- Inbound TCP port `8888` open in the firewall and, if applicable, in the cloud
  provider security group
- At least 3 GB RAM (2 GB are reserved for the Java heap by default) and about
  2 GB of free disk space

**Steps**

1. Clone the repository and enter it:

   ```bash
   git clone <REPOSITORY_URL> minecraft-server && cd minecraft-server
   ```

2. Build the image and start the server:

   ```bash
   docker compose up --detach --build
   ```

3. Wait until the log shows `Done (...)! For help, type "help"`:

   ```bash
   docker compose logs --follow mc-server
   ```

4. Verify that the server answers on port 8888:

   ```bash
   python -m venv .venv && . .venv/bin/activate
   pip install --requirement requirements.txt
   python check_status.py <SERVER_IP>
   ```

5. Connect from the Minecraft Java client to `<SERVER_IP>:8888`.

No `.env` file is needed for this. Create one only to enable RCON, see
[Critical configuration via .env](#critical-configuration-via-env).

## Usage

### How configuration is applied

Settings travel through three layers. Each layer overrides the one above it:

1. **Image defaults** — the `ENV` block in the `Dockerfile`. These guarantee
   that the container can always start.
2. **`docker-compose.yaml`** — the `environment` block, holding the
   non-critical settings of this deployment.
3. **`.env`** — the untracked file holding critical settings, injected through
   `env_file`.

On every start `entrypoint.sh` writes the resulting values into
`data/server.properties`. It rewrites only the keys it manages (the table
below) and copies every other line through unchanged, so hand-tuned settings
such as `spawn-monsters` survive restarts.

Two consequences worth knowing:

- Changing a managed key by hand in `data/server.properties` has no lasting
  effect, because the next start writes the environment value again. Change
  managed keys in `docker-compose.yaml` instead.
- The Minecraft server rewrites `server.properties` itself on startup, using its
  own canonical format. It keeps all property keys but discards free-form
  comment lines.

### Non-critical configuration

These are set in the `environment` block of `docker-compose.yaml`. They contain
no authentication data and are safe to track in git.

| Variable | Default | `server.properties` key | Description |
|---|---|---|---|
| `EULA` | `true` | *(writes `eula.txt`)* | Accepts the [Minecraft EULA](https://www.minecraft.net/eula). The server refuses to run without it. |
| `JAVA_MEMORY` | `2G` | *(JVM flag)* | Java heap size, used for both `-Xms` and `-Xmx`, e.g. `1G`, `4G`. |
| `JAVA_OPTS` | *(empty)* | *(JVM flags)* | Additional JVM flags, separated by spaces. |
| `MOTD` | `Minecraft Server (Docker)` | `motd` | Text shown in the server list of the client. |
| `DIFFICULTY` | `normal` | `difficulty` | `peaceful`, `easy`, `normal` or `hard`. |
| `GAMEMODE` | `survival` | `gamemode` | `survival`, `creative`, `adventure` or `spectator`. |
| `LEVEL_NAME` | `world` | `level-name` | Name of the world directory inside `data/`. |
| `LEVEL_SEED` | *(empty)* | `level-seed` | World generation seed. Empty means random. Only affects a world that does not exist yet. |
| `MAX_PLAYERS` | `10` | `max-players` | Maximum number of simultaneous players. |
| `VIEW_DISTANCE` | `10` | `view-distance` | Sent chunk radius. Lower values reduce CPU and bandwidth. |
| `SIMULATION_DISTANCE` | `10` | `simulation-distance` | Radius in which entities and blocks are simulated. |
| `SPAWN_PROTECTION` | `16` | `spawn-protection` | Radius around spawn that only operators may edit. `0` disables it. |
| `ONLINE_MODE` | `true` | `online-mode` | Verifies player accounts with Mojang. Keep this enabled. |
| `PVP` | `true` | `pvp` | Allows players to damage each other. |
| `ENABLE_COMMAND_BLOCK` | `false` | `enable-command-block` | Allows command blocks in the world. |
| `RCON_PORT` | `25575` | `rcon.port` | Container-internal RCON port. Never published to the internet. |

**Example** — a creative server for 20 players with more memory:

```yaml
    environment:
      GAMEMODE: "creative"
      MAX_PLAYERS: "20"
      JAVA_MEMORY: "4G"
```

Apply the change. No rebuild is required, because these are runtime values:

```bash
docker compose up --detach
```

### Critical configuration via .env

Passwords, tokens and user names must never be tracked. They are read from the
`.env` file, which `.gitignore` excludes. Create it from the template:

```bash
cp .env.example .env
chmod 600 .env
```

| Variable | Default | Description |
|---|---|---|
| `RCON_PASSWORD` | *(empty)* | Password for the remote console. Empty keeps RCON switched off. |
| `MINECRAFT_VERSION` | `26.3` | Optional override of the built Minecraft version. |
| `MC_HOST_PORT` | `8888` | Optional override of the published host port. |

Generate a strong RCON password and apply it:

```bash
sed --in-place "s|^RCON_PASSWORD=.*|RCON_PASSWORD=$(openssl rand -hex 24)|" .env
docker compose up --detach
```

The service declares this file as `required: false`, so the server still starts
when no `.env` exists.

### Changing the published port

The host port is interpolated from `MC_HOST_PORT` and defaults to `8888`. The
container-internal port stays `25565`:

```yaml
    ports:
      - "${MC_HOST_PORT:-8888}:25565/tcp"
```

Either set `MC_HOST_PORT` in `.env`, or edit the left-hand side of the mapping.
Remember to open the new port in the firewall.

### Changing the Minecraft version

The version is a build argument, so changing it requires a rebuild:

```bash
echo 'MINECRAFT_VERSION=<VERSION>' >> .env
docker compose up --detach --build
```

Alternatively edit the default in `docker-compose.yaml`:

```yaml
    build:
      args:
        MINECRAFT_VERSION: "<VERSION>"
```

A newer Minecraft version may require a newer Java runtime. Check which one a
target version needs:

```bash
MANIFEST_URL='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
export MINECRAFT_VERSION='<VERSION>'
curl --silent --location "${MANIFEST_URL}" \
  | jq --raw-output '.versions[] | select(.id == env.MINECRAFT_VERSION) | .url' \
  | xargs curl --silent --location \
  | jq '.javaVersion.majorVersion'
```

If the result differs from `25`, adjust the `JAVA_MAJOR_VERSION` build argument
in the `Dockerfile`, which selects the `openjdk-<VERSION>-jre-headless` package.

### Persistence and backups

The host directory `./data` is bind-mounted to `/data` inside the container and
holds the world, `server.properties`, `eula.txt`, `ops.json`, `whitelist.json`,
the downloaded libraries and the logs.

Because the game state lives outside the container, it survives
`docker compose restart`, `docker compose down` followed by `up`, a rebuild of
the image and a reboot of the host.

Create a backup from a stopped server, which guarantees a consistent world:

```bash
docker compose stop
sudo tar --create --gzip --file "mc-backup-$(date +%F-%H%M).tar.gz" data/
docker compose start
```

Restore it:

```bash
docker compose down
sudo rm --recursive --force data/
sudo tar --extract --gzip --file mc-backup-<TIMESTAMP>.tar.gz
docker compose up --detach
```

To start over with a fresh world, stop the server and remove the world
directory only, because `data/` also holds configuration you may want to keep:

```bash
docker compose down
sudo rm --recursive --force data/world
docker compose up --detach
```

### Server console and operator rights

The service keeps stdin open and allocates a TTY, so the interactive server
console is reachable:

```bash
docker attach mc-server
```

Grant yourself operator rights by typing into that console:

```
op <YOUR_MINECRAFT_USERNAME>
```

Detach again with **Ctrl+P** followed by **Ctrl+Q**. Do not press Ctrl+C, which
would terminate the server.

### Automatic restart after a failure

The service uses `restart: unless-stopped`. Docker restarts the container
whenever it terminates with a non-zero exit code, and also after a reboot of the
host. It stays down only after a deliberate `docker compose stop` or
`docker compose down`.

Inspect the policy and how often it has triggered:

```bash
docker inspect --format 'policy={{.HostConfig.RestartPolicy.Name}} restarts={{.RestartCount}} status={{.State.Status}}' mc-server
```

Note that `docker kill` is treated by Docker as a deliberate stop and therefore
does **not** trigger the restart policy. To observe the policy, provoke a real
startup failure instead:

```bash
docker exec --user 0 mc-server mv /opt/minecraft/server.jar /opt/hidden.jar
docker restart mc-server
docker inspect --format 'restarts={{.RestartCount}} exit={{.State.ExitCode}}' mc-server
docker logs --tail 3 mc-server
```

The container now fails and is restarted repeatedly. Return to a healthy
container, which is recreated from the unmodified image:

```bash
docker compose down && docker compose up --detach --force-recreate
```

### Stopping the server safely

Because `entrypoint.sh` starts the server with `exec`, the Java process is PID 1
and receives `SIGTERM` directly. The Minecraft shutdown hook then saves the world
before the process exits. `stop_grace_period: 120s` gives it ample time even for
a large world.

```bash
docker compose stop
```

The TTY closes at the same moment, so the last log lines of the shutdown are
usually cut off. The save still happens; the modification time of
`data/world/level.dat` is updated at the moment of the stop.

### Using RCON

RCON is enabled only when `RCON_PASSWORD` is set, and it is deliberately **not**
published to the internet. Reach it from inside the container network, for
example with a throwaway client container:

```bash
docker run --rm --interactive --tty --network minecraft-server_default outdead/rcon:latest --address mc-server:25575 --password "${RCON_PASSWORD}" "list"
```

For everyday administration `docker attach mc-server` is simpler.

## Testing

**1. Reachability from the outside.** Run `check_status.py` from a machine that
is not the server. It performs the same Server List Ping as the Minecraft
client:

```bash
python -m venv .venv && . .venv/bin/activate
pip install --requirement requirements.txt
python check_status.py <SERVER_IP>
```

Expected output:

```
OK      <SERVER_IP>:8888 is online
        version:  26.3
        players:  0/10
        motd:     Minecraft Server (Docker)
        latency:  73 ms
```

The script exits with `0` when the server answered and `1` when it did not, so
it can also be used in scripts. Pass `HOST:PORT` to test a different port.

**2. Connect with the game client.** Add the server as `<SERVER_IP>:8888` in the
Minecraft Java client and join.

**3. Persistence across a restart.** Build a block or drop an item, then
recreate the container and confirm that the world and the configuration are
still there:

```bash
docker compose down
docker compose up --detach
docker compose logs mc-server | grep --count 'No existing world data'
```

A count of `0` proves that the existing world was reused rather than
regenerated.

**4. Automatic restart on failure.** See
[Automatic restart after a failure](#automatic-restart-after-a-failure).

**5. Unprivileged process.** Confirm that the server does not run as root:

```bash
docker exec mc-server sh -c 'grep ^Uid: /proc/1/status'
```

The expected UID is `999`, the `minecraft` account, not `0`.

## Security Notes

- No passwords, tokens, user names, IP addresses or SSH keys are stored in this
  repository. The documentation uses placeholders such as `<SERVER_IP>` and
  `<YOUR_MINECRAFT_USERNAME>`.
- Critical configuration reaches the container exclusively through the `.env`
  file, which `.gitignore` excludes. `.env.example` contains placeholders only.
- The server process runs as the unprivileged system account `minecraft`
  (UID 999). Root is used only to prepare the mounted volume and is dropped
  before the server starts.
- `server.jar` is downloaded from the official Mojang distribution host and
  verified against the SHA1 checksum from the official version metadata. A
  mismatch fails the build.
- `curl` and `jq` exist only in the build stage and are absent from the shipped
  image.
- Only the game port is published. RCON listens on the container network only
  and stays disabled unless a password is configured.
- `ONLINE_MODE` defaults to `true`, so player accounts are verified with Mojang.
  Disabling it allows anyone to join under any name.
