#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

readonly PROJECT_NAME="proxy_deploy"
readonly PROJECT_DIR="/root/${PROJECT_NAME}-main"
readonly COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

declare -ar COMPOSE=(
    docker compose
    -p "$PROJECT_NAME"
    -f "$COMPOSE_FILE"
)

network_namespace()
{
    local service="$1"
    local container_id pid

    container_id="$("${COMPOSE[@]}" ps -q "$service")"
    [[ -n "$container_id" ]] || return 1

    pid="$(docker inspect --format '{{.State.Pid}}' "$container_id")"
    [[ "$pid" -gt 0 ]] || return 1

    readlink "/proc/$pid/ns/net"
}

repair_warp_dependents()
{
    local warp_ns ss_warp_ns gost_warp_ns

    warp_ns="$(network_namespace warp)" || return 0
    ss_warp_ns="$(network_namespace ss_warp 2>/dev/null || true)"
    gost_warp_ns="$(network_namespace gost_warp 2>/dev/null || true)"

    if [[ "$warp_ns" != "$ss_warp_ns" ||
          "$warp_ns" != "$gost_warp_ns" ]]
    then
        echo "WARP network namespace changed; recreating dependent services"
        "${COMPOSE[@]}" up -d --no-deps --force-recreate \
            ss_warp gost_warp
    fi
}

# Repair a restart that may have happened while the event listener was offline.
repair_warp_dependents

docker events \
    --filter type=container \
    --filter event=start \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter label=com.docker.compose.service=warp \
    --format '{{.ID}}' |
while read -r _
do
    sleep 5
    repair_warp_dependents
done
