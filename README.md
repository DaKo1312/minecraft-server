# Minecraft Server on Docker

A **Minecraft Java Edition** server with the Fabric mod loader and a small set
of pinned server-side mods, built from a plain Debian base image and deployed
with Docker Compose. No pre-built Minecraft image is used.

## Table of Contents

- [Description](#description)
- [Repository Contents](#repository-contents)
- [Quickstart](#quickstart)
- [Usage](#usage)
  - [Configuration](#configuration)
  - [Mods](#mods)
  - [Secrets via .env](#secrets-via-env)
  - [Changing the port](#changing-the-port)
  - [Changing the Minecraft version](#changing-the-minecraft-version)
  - [Persistence and backups](#persistence-and-backups)
  - [Console and operator rights](#console-and-operator-rights)
  - [Restart behaviour](#restart-behaviour)
- [Testing](#testing)
- [Security](#security)

## Description

Everything needed to build, configure and run a Minecraft server in a container
on a cloud VM. The purpose is reproducibility: the same commands produce the
same server on any Docker host, the world survives restarts and rebuilds, and
settings are changed through configuration instead of by editing files inside a
running container.

- **Two-stage build.** Stage one downloads `server.jar` from the official Mojang
  metadata, the Fabric mod loader and the mods, and verifies every one of them
  against a published checksum; a mismatch fails the build. Stage two receives
  only the verified files, so `curl` and `jq` never ship.
- **Own base image.** `debian:trixie-slim` plus the headless Java runtime the
  version needs. Minecraft 26.3 requires Java 25.
- **Modded, but still official.** Fabric runs on top of the verified Mojang
  `server.jar` instead of replacing it. The mods are part of the image, not of
  the volume, and all of them are server-side only, so an unmodified client can
  join.
- **Unprivileged.** The server runs as the system account `minecraft` (UID 999).
- **Opt-in EULA.** Nothing starts until the operator accepts the Minecraft
  EULA; every other setting has a default in the image.
- **Persistent.** World, config and logs live in a bind mount on the host.
- **Self-healing.** `restart: unless-stopped` recovers from crashes and reboots.

## Repository Contents

| File | Description |
|---|---|
| `Dockerfile` | Two-stage build: downloads and verifies `server.jar`, the Fabric loader and the mods, installs the Java runtime, creates the unprivileged account, defines all defaults. |
| `mods.txt` | The mods that go into the image, each pinned to one version and one SHA512 checksum. |
| `entrypoint.sh` | Refuses to start without an accepted EULA, writes the Fabric launcher properties and the environment-driven keys of `server.properties`, enables RCON when a password exists, drops root and execs the server as PID 1. |
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
cp .env.example .env                       # then set EULA=true in .env
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

The `.env` file is where the EULA is accepted; RCON is switched on there too.

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
| `EULA` | `false` | Set it to `true` in `.env` to accept the [Minecraft EULA](https://www.minecraft.net/eula). The server refuses to start otherwise. |
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
| `WHITE_LIST` | `false` | Restricts logins to the names in `data/whitelist.json`. Minecraft 26.3 turns this on by default, which locks out every player; the default here keeps the server joinable. |
| `ENABLE_COMMAND_BLOCK` | `false` | Allows command blocks. |
| `RCON_PORT` | `25575` | Container-internal RCON port, never published. |

Example — a creative server for 20 players:

```yaml
    environment:
      GAMEMODE: "creative"
      MAX_PLAYERS: "20"
```

Apply with `docker compose up --detach`; no rebuild needed.

### Mods

The image ships the Fabric mod loader and four mods, chosen for a small cloud
VM: they lower the CPU and memory the server needs and make its load
measurable. All of them are server-side only, so an unmodified Minecraft client
can join.

| Mod | Why it is installed |
|---|---|
| Fabric API | Library the mods below build on; spark needs three of its modules. |
| Lithium | Optimises the server tick loop without changing game behaviour. |
| FerriteCore | Lowers the memory used for block states and chunk data. |
| spark | Profiler: `spark tps` and `spark health` report tick rate, CPU and memory. |

In the server console the commands are typed without a leading slash, as shown
above; a game client needs `/spark tps`. See
[Console and operator rights](#console-and-operator-rights) for how to reach
the console.

The loader does not replace the server application. `entrypoint.sh` writes
`data/fabric-server-launcher.properties` with `serverJar` pointing at the
verified Mojang `server.jar`, and passes `-Dfabric.addMods` so the four mods
above are loaded straight out of the image. They are part of the image, not of
the volume, which is why a rebuild is what changes them.

Fabric also reads `data/mods`, which stays empty here. A jar dropped in there
is loaded as well, which is handy for trying a mod out, but it is not
reproducible: anything that should stay belongs in `mods.txt`.

Check what was loaded:

```bash
docker compose logs mc-server | grep --after-context 4 'Mods from'
```

To add or remove a mod, edit `mods.txt` and rebuild. Each line is
`<SHA512>  <file name>  <URL>`; the SHA512 is shown on the mod's download page
and the build fails if a file does not match it.

```bash
docker compose up --detach --build
```

Pick versions that match both the Minecraft version and the Fabric loader, and
prefer server-side mods: a client-side mod would force every player to install
it.

### Secrets via .env

Passwords and tokens are never tracked. `cp .env.example .env && chmod 600 .env`,
then set what you need. The file is declared `required: false`, so `docker
compose` works without it; the server then stops at the EULA check and says so.

| Variable | Description |
|---|---|
| `EULA` | Set to `true` to accept the [Minecraft EULA](https://www.minecraft.net/eula). Nothing starts without it. |
| `RCON_PASSWORD` | Remote console password. Empty keeps RCON off. RCON stays on the container network and is never published. |
| `MINECRAFT_VERSION` | Overrides the built version (needs a rebuild). |
| `MC_HOST_PORT` | Overrides the published host port. |
| `JAVA_MEMORY` | Overrides the heap size, e.g. `1536M` on a small host. |

`EULA` and `RCON_PASSWORD` are the two that belong here by nature; the rest
live here because they differ per machine, which keeps the tracked files
identical everywhere.

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

## Security

- No secrets, IP addresses or user names are tracked; the documentation uses
  placeholders such as `<SERVER_IP>`.
- Critical configuration reaches the container only through the untracked
  `.env`.
- The server process runs unprivileged; root is dropped before it starts.
- `server.jar` is verified against the SHA1 checksum from Mojang at build time.
- Only the game port is published. RCON stays internal and is off by default.
- `ONLINE_MODE` defaults to `true`, so accounts are verified with Mojang.
- The server is open to any verified account. To limit it to known players, set
  `WHITE_LIST=true` and add them to `data/whitelist.json`.
