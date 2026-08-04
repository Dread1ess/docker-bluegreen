# Docker BlueGreen

Universal Blue-Green deployment script for Docker with automatic rollback and zero-downtime releases.

## What it does

A single Bash script that runs your app in **two** containers — `blue` and `green` — so you can ship new
versions with almost no downtime:

1. A new version is deployed into the **idle** container.
2. It is verified with a health check (HTTP, command, or container-status only).
3. Only after a successful check is traffic **switched** to it.
4. If the check fails, the new container is discarded and the **old version keeps serving traffic**.
5. You can roll back to the previous version at any time with a single command.

## Features

- Zero-downtime Blue-Green switching between two named containers.
- Three health-check modes: **HTTP URL**, **shell command inside the container**, or **container-status only**.
- Automatic rollback on a failed start or a failed health check.
- Explicit `rollback` command to restore the previous release.
- Multi-port publishing and arbitrary `docker run` arguments (volumes, env, networks…).
- **Reverse-proxy mode** for nginx/traefik/caddy setups (no host ports published).
- Shared state volumes so databases/files survive a switch.
- Settings via environment variables, a `deploy.env` file, or inline defaults.
- No dependencies beyond Docker and `curl` (curl only needed for HTTP checks).

## Requirements

- Bash 4+
- Docker (locally reachable via `docker` — override with `DOCKER=`)
- `curl` (only if you use `HEALTHCHECK_URL`)
- A writable `/tmp` directory for the rollback state file

## Quick start

```bash
# 1. Copy the script to your server and make it executable
cp docker-bluegreen.sh /opt/myapp/
chmod +x /opt/myapp/docker-bluegreen.sh

# 2. Create a deploy.env next to it (optional but recommended)
cat > /opt/myapp/deploy.env <<'EOF'
APP_NAME="web"
IMAGE="myregistry.local/web:1.0.0"
HOST_PORTS="80:80 443:443"
DOCKER_RUN_ARGS="-v /srv/web-data:/data --restart unless-stopped"
HEALTHCHECK_URL="http://localhost/health"
EOF

# 3. Deploy
/opt/myapp/docker-bluegreen.sh deploy
```

## Commands

```bash
./docker-bluegreen.sh deploy [-t TAG]   # deploy a new version (TAG overrides the image tag)
./docker-bluegreen.sh rollback          # switch back to the previous version
./docker-bluegreen.sh status            # show container status and images
./docker-bluegreen.sh logs [blue|green] # follow container logs (default: blue)
./docker-bluegreen.sh down              # remove both containers and the state file
./docker-bluegreen.sh help              # show usage
```

### Example: switching releases

```bash
./docker-bluegreen.sh deploy -t web:2.0.0   # deploy v2.0.0 into the idle copy and switch
./docker-bluegreen.sh rollback              # go back to the previous image
```

## How it works

The script keeps exactly two containers of your app, named `APP_NAME-blue` and `APP_NAME-green`.
One is active, the other idle.

```
                ┌───────────────┐    ┌───────────────┐
  internet ────▶│   ACTIVE      │    │     IDLE      │
   (port)       │ app:latest    │    │  (new release)│
                └───────────────┘    └───────────────┘
                       blue              green
                   (serving users)   (waiting for health check)
```

A `deploy` does:

1. Start the **idle** container with the requested image.
2. Wait for it to reach the `running` state.
3. Run the health check.
4. If it passed — **switch** traffic and stop/remove the old active container.
5. If it failed — remove the new container and leave the old one untouched.

The last *old* image is recorded in a state file (`/tmp/<app>.bluegreen.state`) so `rollback` knows
what to restore.

### Direct-port mode (default)

Host ports are published (`HOST_PORTS`). Switching simply stops the old container and leaves the new
one listening on the ports.

### Reverse-proxy mode

For nginx/traefik/caddy, set `USE_REVERSE_PROXY=true`. The script no longer publishes ports — it only
manages the containers and hands over a **switch pointer**:

- Each container is labelled `bluegreen.active=true`, `bluegreen.color=<blue|green>`, and
  `bluegreen.app=<APP_NAME>`.
- Point your proxy at the container whose label is `bluegreen.active=true`, or
- Provide `SWITCH_COMMAND` (e.g. `systemctl reload nginx`) which runs after a successful health check.

The old container is removed on switch, so only one active container remains.

## Configuration

Settings are read with this priority (highest first):

1. **Environment variables**
2. **`deploy.env`** file next to the script (auto-loaded)
3. **Defaults** written at the top of the script

> Environment variables are **not** overridden by `deploy.env`. If both a shell variable and
> `deploy.env` define the same key, the shell (or command-line, e.g. `-t`) wins.

Specify a custom config file location with `ENV_FILE=/custom/path.env` if you don't use the default
`deploy.env` next to the script.

### Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_NAME` | `myapp` | Short app name; prefixes container names (`${APP_NAME}-blue`, `…-green`). |
| `IMAGE` | `myapp:latest` | Image to deploy. A tag can be overridden on the CLI with `deploy -t`. |
| `HOST_PORTS` | `8080:80` | Space-separated `host:container` ports to publish. Quote it. |
| `USE_REVERSE_PROXY` | `false` | `true` → don't publish ports; an external proxy (or `SWITCH_COMMAND`) routes traffic. |
| `DOCKER_RUN_ARGS` | `--restart unless-stopped` | Extra args for `docker run` (volumes, env, network…). |
| `DOCKER_NETWORK` | *(empty)* | Join this Docker network. Empty uses the default. |
| `HEALTHCHECK_URL` | *(empty)* | HTTP(S) check target, e.g. `http://localhost:8080/health`. Requires `curl`. |
| `HEALTHCHECK_CMD` | *(empty)* | Command run inside the container, e.g. `wget -q -O - http://localhost/health`. |
| `START_TIMEOUT` | `60` | Seconds to wait for a container to reach `running`. |
| `HEALTH_RETRIES` | `15` | Number of health-check attempts (2s apart ⇒ up to ~30s). |
| `SWITCH_COMMAND` | *(empty)* | Command run when `USE_REVERSE_PROXY=true` after a successful check. |
| `DOCKER` | `docker` | Docker binary path (e.g. `podman`). |
| `ENV_FILE` | `<script dir>/deploy.env` | Alternative path to the config file. |

### Health checks

There are three ways to validate the new container:

**1. HTTP URL** (needs `curl`)
```ini
HEALTHCHECK_URL="http://localhost:8080/health"
```
`curl -fsS` must return success within the retry window.

**2. Command inside the container**
```ini
HEALTHCHECK_CMD="wget -q -O - http://localhost/health"
```
Run with `docker exec <name> sh -lc "<HEALTHCHECK_CMD>"`. Exit code `0` means healthy.

**3. Status only** *(default when neither is set)*
If neither `HEALTHCHECK_URL` nor `HEALTHCHECK_CMD` is set, the script just waits for the container to
be `running`. If host ports **are** published (and reverse-proxy mode is off), it will attempt to
detect the first host port and probe it — otherwise the container-status check is used.

### Example `deploy.env`

```bash
APP_NAME="web"
IMAGE="myregistry.local/web:1.0.0"
HOST_PORTS="80:80 443:443"
DOCKER_RUN_ARGS="-v /srv/web-data:/data --restart unless-stopped"
HEALTHCHECK_URL="http://localhost/health"
# HEALTHCHECK_CMD="wget -q -O - http://localhost/health"

# Reverse-proxy setup instead of publishing ports:
# USE_REVERSE_PROXY=true
# SWITCH_COMMAND="systemctl reload nginx"
```

## Rollback

`rollback` reads the image stored during the last successful switch and restores it into the idle
container, then switches traffic back:

```bash
./docker-bluegreen.sh rollback
```

If the state file is missing (e.g. after a fresh `down`, or before any successful deploy), rollback
refuses with an explicit message.

Rollback is **reversible**: each `rollback` records the image you are switching away from, so running
it a second time returns to the previous release (the two versions toggle back and forth).

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `curl is required for HTTP health checks` | Install `curl`, or use `HEALTHCHECK_CMD`. |
| `Container X stopped working (status: exited)` | App crashed on boot. Inspect its logs: `./docker-bluegreen.sh logs blue`. |
| `Health check failed after N seconds` | Container is up but the check target is wrong/unreachable; verify `HEALTHCHECK_URL` / `HEALTHCHECK_CMD`. |
| `docker not found` | Install Docker, or set `DOCKER=/path/to/docker`. |
| `State file missing … rollback is not possible` | No previous successful switch recorded; use `status` and recover. |

## Security notes

- `SWITCH_COMMAND` is executed from the script (`eval`). **Never** put your shell's dotfiles or
  untrusted values into it — treat it as trusted configuration.
- The script calls `docker exec` and `docker run` with the provided image name; make sure `IMAGE` /
  `-t` values come from trusted sources.

## Limitations

- The ports from `HOST_PORTS` and the arguments in `DOCKER_RUN_ARGS` are expanded into a single
  command-line string. If a value contains spaces (e.g. `-e FOO=hello world`), store it with the
  proper quoting in `deploy.env`; the script does not re-tokenise quotes.
- The rollback state file is stored in `/tmp` — not persistent across reboot.
- Blue-Green with **shared state volumes** is not automatic; add them to `STATE_VOLUMES` in the script
  if both containers need the same data.
