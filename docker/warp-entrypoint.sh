#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

DIRECT_EGRESS_IF="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
readonly KILLSWITCH_CHAIN="WARP_KILLSWITCH"

if [[ -z "$DIRECT_EGRESS_IF" ]]
then
    echo "Unable to determine direct egress interface"
    exit 1
fi

install_killswitch()
{
    local command="$1"

    "$command" -N "$KILLSWITCH_CHAIN" 2>/dev/null || true

    if ! "$command" -C "$KILLSWITCH_CHAIN" \
        -m conntrack --ctstate ESTABLISHED --ctdir REPLY \
        -j RETURN 2>/dev/null
    then
        "$command" -I "$KILLSWITCH_CHAIN" 1 \
            -m conntrack --ctstate ESTABLISHED --ctdir REPLY \
            -j RETURN
    fi

    if ! "$command" -C "$KILLSWITCH_CHAIN" -j REJECT 2>/dev/null
    then
        "$command" -A "$KILLSWITCH_CHAIN" -j REJECT
    fi

    if ! "$command" -C OUTPUT \
        -o "$DIRECT_EGRESS_IF" \
        -m owner --uid-owner 65534 \
        -j "$KILLSWITCH_CHAIN" 2>/dev/null
    then
        "$command" -I OUTPUT 1 \
            -o "$DIRECT_EGRESS_IF" \
            -m owner --uid-owner 65534 \
            -j "$KILLSWITCH_CHAIN"
    fi
}

install_killswitch iptables
install_killswitch ip6tables

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

if ! warp-cli --accept-tos registration show >/dev/null 2>&1
then
    warp-cli --accept-tos registration delete || true
    warp-cli --accept-tos registration new
fi

warp-cli --accept-tos mode warp
warp-cli --accept-tos connect || true

while true
do
    if ! kill -0 "$WARP_SVC_PID" 2>/dev/null
    then
        echo "warp-svc exited; restarting container"
        wait "$WARP_SVC_PID" || true
        exit 1
    fi

    if ! warp-cli --accept-tos status | grep -q 'Connected'
    then
        echo "WARP disconnected; reconnecting"
        warp-cli --accept-tos connect || true
    fi

    sleep 30
done
