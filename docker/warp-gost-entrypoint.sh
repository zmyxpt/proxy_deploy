#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

warp-svc &
WARP_SVC_PID=$!

until warp-cli --accept-tos status >/dev/null 2>&1
do
    if ! kill -0 "$WARP_SVC_PID" 2>/dev/null
    then
        echo "warp-svc exited during startup"
        wait "$WARP_SVC_PID" || true
        exit 1
    fi
    sleep 1
done

if ! warp-cli --accept-tos account >/dev/null 2>&1
then
    warp-cli --accept-tos registration delete || true
    warp-cli --accept-tos registration new
fi

warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40001
warp-cli --accept-tos connect || true

socat "TCP-LISTEN:40000,fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:40001" &
SOCAT_PID=$!

while true
do
    if ! kill -0 "$WARP_SVC_PID" 2>/dev/null
    then
        echo "warp-svc exited; restarting container"
        wait "$WARP_SVC_PID" || true
        exit 1
    fi
    if ! kill -0 "$SOCAT_PID" 2>/dev/null
    then
        echo "socat exited; restarting container"
        wait "$SOCAT_PID" || true
        exit 1
    fi
    if ! warp-cli --accept-tos status | grep -q 'Connected'
    then
        echo "WARP disconnected; reconnecting"
        warp-cli --accept-tos connect || true
    fi
    sleep 30
done
