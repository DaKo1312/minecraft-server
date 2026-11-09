# Minecraft Server on Docker

A vanilla **Minecraft Java Edition** server, built from a plain Debian base
image and deployed with Docker Compose. No pre-built Minecraft image is used.

## Table of Contents

- [Description](#description)
- [Repository Contents](#repository-contents)
- [Quickstart](#quickstart)
- [Usage](#usage)
  - [Configuration](#configuration)
  - [Secrets via .env](#secrets-via-env)
  - [Changing the port](#changing-the-port)
  - [Changing the Minecraft version](#changing-the-minecraft-version)
  - [Persistence and backups](#persistence-and-backups)
  - [Console and operator rights](#console-and-operator-rights)
  - [Restart behaviour](#restart-behaviour)
- [Testing](#testing)

## Description

Everything needed to build, configure and run a Minecraft server in a container
on a cloud VM. The purpose is reproducibility: the same commands produce the
same server on any Docker host, the world survives restarts and rebuilds, and
settings are changed through configuration instead of by editing files inside a
running container.

- **Two-stage build.** Stage one downloads `server.jar` from the official Mojang
  metadata and verifies its SHA1 checksum; a mismatch fails the build. Stage two
  receives only the verified file, so `curl` and `jq` never ship.
- **Own base image.** `debian:trixie-slim` plus the headless Java runtime the
  version needs. Minecraft 26.3 requires Java 25.
- **Unprivileged.** The server runs as the system account `minecraft` (UID 999).
- **Always startable.** Every setting has a default in the image.
- **Persistent.** World, config and logs live in a bind mount on the host.
- **Self-healing.** `restart: unless-stopped` recovers from crashes and reboots.

## Repository Contents

| File | Description |
|---|---|
| `Dockerfile` | Two-stage build: downloads and verifies `server.jar`, installs the Java runtime, creates the unprivileged account, defines all defaults. |
| `entrypoint.sh` | Writes `eula.txt` and the environment-driven keys of `server.properties`, enables RCON when a password exists, drops root and execs the server as PID 1. |
| `docker-compose.yaml` | The `mc-server` service: build args, published port, environment, optional `.env`, volume, restart policy. |
| `.env.example` | Template for the untracked `.env` holding the critical configuration. |
| `.gitignore` | Excludes runtime data, the real `.env`, virtual environments and credential files. |
| `.dockerignore` | Keeps `data/` out of the build context. |
| `check_status.py` | Reachability check via [mcstatus](https://github.com/py-mine/mcstatus). |
| `requirements.txt` | Pinned dependency of `check_status.py`. |
| `docs/checklist.md` | Course submission checklist with every requirement marked and the verification results. |
| `docs/checklist.pdf` | Export of `docs/checklist.md` for handing in. |
| `README.md` | This documentation. |

Created at runtime and untracked: `data/` (world, config, logs) and `.venv/`.

## Quickstart

**Requirements:** a Linux VM with a public IP, Docker Engine and Docker Compose
**v2.24+**, inbound TCP `8888` open in the firewall and the cloud security
group, at least 3 GB RAM.

```bash
git clone <REPOSITORY_URL> minecraft-server && cd minecraft-server
docker compose up --detach --build
docker compose logs --follow mc-server     # wait for: Done (...)! For help, type "help"
```

Then connect the Minecraft Java client to `<SERVER_IP>:8888`, or verify from
another machine:

```bash
python -m venv .venv && . .venv/bin/activate
pip install --requirement requirements.txt
python check_status.py <SERVER_IP>
```

No `.env` file is required; create one only to enable RCON.

## Usage

### Configuration

Settings pass through three layers, each overriding the one above: defaults in
the `Dockerfile`, then the `environment` block of `docker-compose.yaml`, then
the untracked `.env`.

On every start `entrypoint.sh` writes the result into `data/server.properties`.
It rewrites only the keys below and leaves every other line alone, so hand-tuned
settings survive. The flip side: editing one of these keys by hand has no
lasting effect — change it in `docker-compose.yaml` instead.

| Variable | Default | Description |
|---|---|---|
| `EULA` | `true` | Accepts the [Minecraft EULA](https://www.minecraft.net/eula). Required to start. |
| `JAVA_MEMORY` | `2G` | Heap size for `-Xms` and `-Xmx`. Overridable per machine via `.env`. |
| `JAVA_OPTS` | *(empty)* | Extra JVM flags, space separated. |
| `MOTD` | `Minecraft Server (Docker)` | Text in the client server list. |
| `DIFFICULTY` | `normal` | `peaceful`, `easy`, `normal`, `hard`. |
| `GAMEMODE` | `survival` | `survival`, `creative`, `adventure`, `spectator`. |
| `LEVEL_NAME` | `world` | World directory inside `data/`. |
| `LEVEL_SEED` | *(empty)* | Generation seed; empty means random. Only applies to a new world. |
| `MAX_PLAYERS` | `10` | Simultaneous players. |
| `VIEW_DISTANCE` | `10` | Sent chunk radius. Lower reduces CPU and bandwidth. |
| `SIMULATION_DISTANCE` | `10` | Radius in which entities are simulated. |
| `SPAWN_PROTECTION` | `16` | Radius only operators may edit; `0` disables. |
| `ONLINE_MODE` | `true` | Verifies accounts with Mojang. Keep enabled. |
| `PVP` | `true` | Players can damage each other. |
| `ENABLE_COMMAND_BLOCK` | `false` | Allows command blocks. |
| `RCON_PORT` | `25575` | Container-internal RCON port, never published. |

Example — a creative server for 20 players:

```yaml
    environment:
      GAMEMODE: "creative"
      MAX_PLAYERS: "20"
```

Apply with `docker compose up --detach`; no rebuild needed.

### Secrets via .env

Passwords and tokens are never tracked. `cp .env.example .env && chmod 600 .env`,
then set what you need. The file is declared `required: false`, so the server
still starts without it.

| Variable | Description |
|---|---|
| `RCON_PASSWORD` | Remote console password. Empty keeps RCON off. RCON stays on the container network and is never published. |
| `MINECRAFT_VERSION` | Overrides the built version (needs a rebuild). |
| `MC_HOST_PORT` | Overrides the published host port. |
| `JAVA_MEMORY` | Overrides the heap size, e.g. `1536M` on a small host. |

Only `RCON_PASSWORD` is genuinely critical; the rest live here because they
differ per machine, which keeps the tracked files identical everywhere.

### Changing the port

```yaml
    ports:
      - "${MC_HOST_PORT:-8888}:25565/tcp"
```

Set `MC_HOST_PORT` in `.env` or edit the left side. Open the new port in the
firewall.

### Changing the Minecraft version

```bash
echo 'MINECRAFT_VERSION=<VERSION>' >> .env
docker compose up --detach --build
```

A newer version may need a newer Java runtime. Check which one:

```bash
export MINECRAFT_VERSION='<VERSION>'
curl -sL 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json' \
  | jq -r '.versions[] | select(.id == env.MINECRAFT_VERSION) | .url' \
  | xargs curl -sL | jq '.javaVersion.majorVersion'
```

If it differs from `25`, adjust the `JAVA_MAJOR_VERSION` build argument in the
`Dockerfile`.

### Persistence and backups

`./data` is bind-mounted to `/data` and holds the world, `server.properties`,
`ops.json`, `whitelist.json` and the logs. The game state therefore survives
`docker compose down`, image rebuilds and host reboots.

```bash
docker compose stop
sudo tar --create --gzip --file "mc-backup-$(date +%F).tar.gz" data/
docker compose start
```

To start a fresh world, stop the server and remove `data/world` only.

### Console and operator rights

```bash
docker attach mc-server
```

Type `op <YOUR_MINECRAFT_USERNAME>`, then detach with **Ctrl+P**, **Ctrl+Q** —
not Ctrl+C, which stops the server.

### Restart behaviour

`restart: unless-stopped` brings the container back after any non-zero exit and
after a host reboot, but not after a deliberate `docker compose stop` or `down`.
Note that `docker kill` counts as deliberate and does **not** trigger the
policy; to see it work, provoke a real startup failure.

On `docker compose stop` the server receives `SIGTERM` directly, because
`entrypoint.sh` execs it as PID 1, and saves the world before exiting. The TTY
closes at the same moment, so the last log lines are usually cut off while the
save still completes.

## Testing

**Reachable on port 8888.** Run this from a machine that is not the server, so
the test really crosses the internet. It performs the same Server List Ping as
the game client and exits `0` on success, `1` on failure:

```bash
python -m venv .venv && . .venv/bin/activate
pip install --requirement requirements.txt
python check_status.py <SERVER_IP>
```

```
OK      <SERVER_IP>:8888 is online
        version:  26.3
        players:  0/10
        motd:     Minecraft Server (Docker)
        latency:  14 ms
```

Alternatively add the server as `<SERVER_IP>:8888` in the Minecraft Java client
and join.

**Data survives a restart.** Build a block, then recreate the container:

```bash
docker compose down && docker compose up --detach
docker compose logs mc-server | grep -c 'No existing world data'   # expect 0
```

A count of `0` means the existing world was reused instead of regenerated.

**Containers restart after a failure.** `docker kill` counts as a deliberate
stop and does not trigger the policy, so provoke a real startup failure:

```bash
docker exec --user 0 mc-server mv /opt/minecraft/server.jar /opt/hidden.jar
docker restart mc-server
docker inspect --format 'restarts={{.RestartCount}} exit={{.State.ExitCode}}' mc-server
docker compose down && docker compose up --detach --force-recreate   # restore
```

`RestartCount` rises while `ExitCode` stays `1`.

The results of these runs are recorded in
[docs/checklist.md](docs/checklist.md).
