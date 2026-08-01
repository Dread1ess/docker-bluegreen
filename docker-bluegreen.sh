#!/usr/bin/env bash
# =============================================================================
#  docker-bluegreen.sh - universal Blue-Green deployment for Docker
#
#  Idea: the app always runs in two copies - "blue" and "green".
#  One is active, the other is idle. A new release goes into the idle copy,
#  is verified by a health check, and only then is traffic switched.
#  If the check fails - automatic rollback, the old version keeps running.
#
#  Setup: copy the "CONFIGURATION" block into a separate file
#  (e.g. ./deploy.env) or edit it right here. The script automatically
#  picks up ./deploy.env if it is located next to the script.
#
#  Usage:
#    ./docker-bluegreen.sh deploy          # deploy a new version
#    ./docker-bluegreen.sh rollback        # roll back to the previous release
#    ./docker-bluegreen.sh status          # show current state
#    ./docker-bluegreen.sh logs [name]     # show container logs (blue|green)
#    ./docker-bluegreen.sh down            # stop both containers
# =============================================================================
set -euo pipefail

# =============================================================================
#  CONFIGURATION
#  Priority: environment variable > deploy.env > defaults below.
# =============================================================================

# Short app name (used in container names and labels)
APP_NAME="${APP_NAME:-myapp}"

# Docker image and tag of the new version (tag can be overridden with -t myapp:v2)
IMAGE="${IMAGE:-myapp:latest}"

# Which ports to publish from the HOST into the container. Write as one string, e.g.:
#   "8080:80"            - single port
#   "8080:80 9090:9090"  - multiple ports (important: keep inside quotes!)
HOST_PORTS="${HOST_PORTS:-8080:80}"

# When enabled (true), ports are NOT published - traffic is expected to be
# distributed by an external reverse proxy (nginx/traefik/caddy). The script
# then only creates/restarts containers.
USE_REVERSE_PROXY="${USE_REVERSE_PROXY:-false}"

# Extra arguments for docker run (volumes, env, network, etc.)
# Example: DOCKER_RUN_ARGS="-v /data:/data -e FOO=bar --network mynet --restart unless-stopped"
DOCKER_RUN_ARGS="${DOCKER_RUN_ARGS:--restart unless-stopped}"

# Network (docker network), if needed. Empty - default network.
DOCKER_NETWORK="${DOCKER_NETWORK:-}"

# URL/command health check for the new container.
#   Option 1 - HTTP: HEALTHCHECK_URL="http://localhost:8080/health"
#   Option 2 - command: HEALTHCHECK_CMD="wget -q -O - http://localhost/health"
# If both are empty - only checks that the container is started and alive.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
HEALTHCHECK_CMD="${HEALTHCHECK_CMD:-}"

# How many seconds to wait for the new container to start
START_TIMEOUT="${START_TIMEOUT:-60}"

# How many times (with a 2s pause) to repeat the health check. Total ~ RETRIES * 2 seconds.
HEALTH_RETRIES="${HEALTH_RETRIES:-15}"

# Command that "switches" traffic when USE_REVERSE_PROXY=true.
# Runs on the active host after a successful health check.
# Example: "systemctl reload nginx"  or  "docker exec nginx nginx -s reload"
SWITCH_COMMAND="${SWITCH_COMMAND:-}"

# docker-compose settings (if you use compose files to describe the container)
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-}"

# =============================================================================
#  NO NEED TO CHANGE BELOW
# =============================================================================

# Container names
CONTAINER_BLUE="${APP_NAME}-blue"
CONTAINER_GREEN="${APP_NAME}-green"

# State volume names (shared by both containers so that database/files are
# not lost on switch). Add your own if needed.
# IMPORTANT: do not duplicate these volumes in DOCKER_RUN_ARGS.
STATE_VOLUMES=()

# Helper file storing the name of the last deployed tag (for rollback)
STATE_FILE="/tmp/${APP_NAME}.bluegreen.state"

DOCKER="${DOCKER:-docker}"

# =============================================================================
#  Helper functions
# =============================================================================

log()  { printf '\033[1;36m[bluegreen]\033[0m %s\n' "$*"; }
info() { printf '\033[1;33m[info]\033[0m      %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m        %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m    %s\n' "$*" >&2; }

# Load deploy.env if it exists next to the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/deploy.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  info "Loaded settings from $ENV_FILE"
fi

# Build the ports string for docker run
build_ports_args() {
  local out=()
  local p
  for p in $HOST_PORTS; do
    out+=("-p" "$p")
  done
  printf '%s\n' "${out[@]}" | paste -sd' ' -
}

# Build the state volumes string
build_volume_args() {
  local out=()
  local v
  for v in "${STATE_VOLUMES[@]}"; do
    out+=("-v" "$v")
  done
  printf '%s\n' "${out[@]}" | paste -sd' ' -
}

# Check that docker is available
require_docker() {
  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    err "docker not found. Install Docker or set DOCKER=/path/to/docker"
    exit 1
  fi
}

# Check whether the container name is free or used by our image
container_state() { # $1 = container name
  local name="$1"
  if "$DOCKER" ps -a --format '{{.Names}}' | grep -qx "$name"; then
    "$DOCKER" inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown"
  else
    echo "absent"
  fi
}

run_container() { # $1 = container name, $2 = image
  local name="$1" img="$2"
  local args
  args="$(build_ports_args) $(build_volume_args) $DOCKER_RUN_ARGS"
  # shellcheck disable=SC2086
  "$DOCKER" run -d --name "$name" \
    -l "bluegreen.app=$APP_NAME" \
    -l "bluegreen.color=${name##*-}" \
    $args \
    "$img" >/dev/null
}

get_health_retries() { echo "$HEALTH_RETRIES"; }

wait_container_ready() { # $1 = container name
  local name="$1" timeout="$START_TIMEOUT" waited=0
  log "Waiting for container $name to start (up to ${timeout}s)..."
  while [[ "$waited" -lt "$timeout" ]]; do
    local st
    st="$(container_state "$name")"
    if [[ "$st" == "running" ]]; then
      return 0
    fi
    if [[ "$st" == "exited" || "$st" == "dead" || "$st" == "restarting" ]]; then
      err "Container $name stopped working (status: $st). Check the logs:"
      "$DOCKER" logs --tail 30 "$name" >&2 || true
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  err "Timeout waiting for $name to start"
  return 1
}

healthcheck() { # $1 = container name
  local name="$1" i
  local port_url="${HEALTHCHECK_URL}"

  # If URL is not set but ports are given - try to guess the first host port
  if [[ -z "$port_url" && -z "$HEALTHCHECK_CMD" && -n "$HOST_PORTS" ]]; then
    local host_port="${HOST_PORTS%%:*}"
    port_url="http://localhost:${host_port%% *}/"
    info "HEALTHCHECK_URL not set, checking first port: $port_url"
  fi

  if [[ -z "$port_url" && -z "$HEALTHCHECK_CMD" ]]; then
    info "No health check configured - considering container ready (status running)"
    return 0
  fi

  for (( i=1; i<=$(get_health_retries); i++ )); do
    local code=0
    if [[ -n "$HEALTHCHECK_CMD" ]]; then
      # shellcheck disable=SC2086
      "$DOCKER" exec "$name" sh -lc "$HEALTHCHECK_CMD" >/dev/null 2>&1 || code=1
    else
      curl -fsS --max-time 3 "$port_url" >/dev/null 2>&1 || code=1
    fi
    if [[ "$code" -eq 0 ]]; then
      ok "Health check passed (attempt $i)"
      return 0
    fi
    sleep 2
  done
  err "Health check failed after $(($(get_health_retries) * 2)) seconds"
  return 1
}

# Start the new container: create it if absent, otherwise recreate it
start_new() { # $1 = container name
  local name="$1"
  local st
  st="$(container_state "$name")"
  if [[ "$st" == "absent" ]]; then
    log "Creating new container $name from image $IMAGE"
    run_container "$name" "$IMAGE"
  else
    log "Container $name exists (status: $st). Removing and recreating from $IMAGE"
    "$DOCKER" rm -f "$name" >/dev/null 2>&1 || true
    run_container "$name" "$IMAGE"
  fi
}

switch_remove_old() { # $1 = old (inactive) container
  local name="$1"
  log "Stopping and removing old container $name"
  "$DOCKER" rm -f "$name" >/dev/null 2>&1 || true
}

# =============================================================================
#  Main commands
# =============================================================================

cmd_deploy() {
  require_docker
  local active inactive
  if [[ "$(container_state "$CONTAINER_BLUE")" == "running" && "$(container_state "$CONTAINER_GREEN")" != "running" ]]; then
    active="$CONTAINER_BLUE"; inactive="$CONTAINER_GREEN"
  else
    active="$CONTAINER_GREEN"; inactive="$CONTAINER_BLUE"
  fi

  # First deployment: no active container yet
  if [[ "$(container_state "$active")" == "absent" && "$(container_state "$inactive")" == "absent" ]]; then
    log "First deployment - starting $active"
    start_new "$active"
    wait_container_ready "$active" || { rollback; exit 1; }
    healthcheck "$active" || { rollback; exit 1; }
    ok "Deployment finished. Active: $active"
    exit 0
  fi

  log "Current state: active=$active, inactive=$inactive"
  info "Deploying new version to the idle container $inactive"

  start_new "$inactive"
  if ! wait_container_ready "$inactive"; then
    err "New container did not start. Rolling back."
    "$DOCKER" rm -f "$inactive" >/dev/null 2>&1 || true
    exit 1
  fi
  if ! healthcheck "$inactive"; then
    err "Health check failed. Rolling back."
    "$DOCKER" rm -f "$inactive" >/dev/null 2>&1 || true
    exit 1
  fi

  # ---- Switch ----
  if [[ "$USE_REVERSE_PROXY" == "true" ]]; then
    if [[ -n "$SWITCH_COMMAND" ]]; then
      log "Switching traffic to $inactive: $SWITCH_COMMAND"
      # shellcheck disable=SC2086
      eval "$SWITCH_COMMAND"
    else
      info "USE_REVERSE_PROXY=true, but SWITCH_COMMAND is not set."
      info "Hint: configure your reverse proxy to select the container with label 'active=true', or set SWITCH_COMMAND."
    fi
    "$DOCKER" rm -f "$active" >/dev/null 2>&1 || true
  else
    log "Stopping old active container $active"
    "$DOCKER" stop "$active" >/dev/null
  fi

  # Save the previous image for rollback
  "$DOCKER" inspect -f '{{.Config.Image}}' "$inactive" > "$STATE_FILE" 2>/dev/null || true

  ok "Deployment finished. Active: $inactive"
}

cmd_rollback() {
  require_docker
  local active inactive prev_image
  if [[ "$(container_state "$CONTAINER_BLUE")" == "running" && "$(container_state "$CONTAINER_GREEN")" != "running" ]]; then
    active="$CONTAINER_BLUE"; inactive="$CONTAINER_GREEN"
  else
    active="$CONTAINER_GREEN"; inactive="$CONTAINER_BLUE"
  fi

  if [[ -f "$STATE_FILE" ]]; then
    prev_image="$(cat "$STATE_FILE")"
    log "Rolling back to image: $prev_image"
  else
    info "State file missing, rollback is not possible (no previous version)"
    exit 1
  fi

  # Start the previous version in the inactive container
  start_new "$inactive"
  if ! wait_container_ready "$inactive"; then
    err "Rollback failed: container $inactive did not start"
    "$DOCKER" rm -f "$inactive" >/dev/null 2>&1 || true
    exit 1
  fi

  log "Switching traffic back to $inactive"
  if [[ "$USE_REVERSE_PROXY" == "true" ]]; then
    [[ -n "$SWITCH_COMMAND" ]] && eval "$SWITCH_COMMAND"
  fi
  "$DOCKER" stop "$active" >/dev/null 2>&1 || true
  "$DOCKER" rm -f "$active" >/dev/null 2>&1 || true
  ok "Rollback finished. Active: $inactive"
}

cmd_status() {
  require_docker
  printf '%-20s %-12s %s\n' "Container" "Status" "Image"
  local name st
  for name in "$CONTAINER_BLUE" "$CONTAINER_GREEN"; do
    st="$(container_state "$name")"
    if [[ "$st" == "absent" ]]; then
      printf '%-20s %-12s %s\n' "$name" "$st" "-"
    else
      local img
      img="$("$DOCKER" inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || echo "-")"
      printf '%-20s %-12s %s\n' "$name" "$st" "$img"
    fi
  done
  if [[ -f "$STATE_FILE" ]]; then
    info "Last version available for rollback: $(cat "$STATE_FILE")"
  fi
}

cmd_logs() {
  require_docker
  local name="${1:-}"
  case "$name" in
    blue) name="$CONTAINER_BLUE" ;;
    green) name="$CONTAINER_GREEN" ;;
    "") name="$CONTAINER_BLUE" ;;
  esac
  if [[ "$(container_state "$name")" == "absent" ]]; then
    err "Container $name does not exist"
    exit 1
  fi
  "$DOCKER" logs -f --tail 100 "$name"
}

cmd_down() {
  require_docker
  log "Stopping all $APP_NAME containers"
  "$DOCKER" rm -f "$CONTAINER_BLUE" "$CONTAINER_GREEN" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
  ok "Done"
}

usage() {
  cat <<EOF
docker-bluegreen.sh - Blue-Green deployment for Docker

Usage:
  $0 deploy [-t TAG]         Deploy a new version (tag can be set with -t)
  $0 rollback                Roll back to the previous version
  $0 status                  Show container status
  $0 logs [blue|green]       Show container logs
  $0 down                    Stop and remove both containers

Settings are read from:
  1. Environment variables
  2. deploy.env file next to the script
  3. Defaults at the top of the script

Example deploy.env:
  APP_NAME="web"
  IMAGE="myregistry.local/web:1.0.0"
  HOST_PORTS="80:80 443:443"
  DOCKER_RUN_ARGS="-v /srv/web-data:/data --restart unless-stopped"
  HEALTHCHECK_URL="http://localhost/health"
  # Or for a reverse proxy:
  # USE_REVERSE_PROXY=true
  # SWITCH_COMMAND="systemctl reload nginx"
EOF
}

# =============================================================================
#  Argument parsing
# =============================================================================

CMD="${1:-}"
shift || true

case "$CMD" in
  deploy)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) IMAGE="${2:-$IMAGE}"; shift 2 ;;
        *) shift ;;
      esac
    done
    cmd_deploy
    ;;
  rollback) cmd_rollback ;;
  status) cmd_status ;;
  logs) cmd_logs "${1:-}" ;;
  down) cmd_down ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
