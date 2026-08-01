# docker-bluegreen

Universal Blue-Green deployment script for Docker with automatic rollback.

## How it works

The app always runs in two copies: `blue` and `green`. A new release goes
into the idle copy, is verified by a health check, and only then is traffic
switched. If the check fails — the old version keeps running.

## Usage

```bash
./docker-bluegreen.sh deploy [-t TAG]   # deploy a new version
./docker-bluegreen.sh rollback          # roll back to the previous version
./docker-bluegreen.sh status            # show container status
./docker-bluegreen.sh logs [blue|green] # show container logs
./docker-bluegreen.sh down              # stop and remove both containers
```

## Setup

Copy `docker-bluegreen.sh` to your server, then create a `deploy.env`
file next to it (the script loads it automatically):

```bash
APP_NAME="web"
IMAGE="myregistry.local/web:1.0.0"
HOST_PORTS="80:80 443:443"
DOCKER_RUN_ARGS="-v /srv/web-data:/data --restart unless-stopped"
HEALTHCHECK_URL="http://localhost/health"
```

Settings priority: environment variables > `deploy.env` > defaults in the script.

### Reverse proxy mode

```bash
USE_REVERSE_PROXY=true
SWITCH_COMMAND="systemctl reload nginx"
```

## Features

- HTTP or command-based health check (or container-status only)
- Multiple port publishing, arbitrary `docker run` args
- Works with any reverse proxy (nginx/traefik/caddy)
- Automatic rollback on failed deploy
