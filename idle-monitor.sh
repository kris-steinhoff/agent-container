#!/bin/sh
set -eu

# Idle monitor for the cloud (Fargate) path. entrypoint.sh runs this as its
# foreground process (with sshd backgrounded) when IDLE_MONITOR=1. When the box
# has been idle long enough it stops the herdr server, kills sshd, and exits 0
# — which stops the task (STOPPED = $0). `./up cloud` starts a fresh one later.
#
# Idle == herdr reports no active agent AND no established inbound SSH. All the
# thresholds below are overridable via the task definition's environment.
IDLE_TIMEOUT="${IDLE_TIMEOUT:-129600}"      # idle must hold this long to trigger (36h)
STARTUP_GRACE="${STARTUP_GRACE:-1200}"      # never trigger within this of boot (20m)
IDLE_POLL_INTERVAL="${IDLE_POLL_INTERVAL:-120}"

log() {
    printf '%s idle-monitor: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

boot=$(date +%s)
idle_since=""

log "started (idle_timeout=${IDLE_TIMEOUT}s startup_grace=${STARTUP_GRACE}s poll=${IDLE_POLL_INTERVAL}s)"

shutdown() {
    log "$1 — stopping herdr server and sshd, exiting 0"
    su - agent -c 'herdr server stop' >/dev/null 2>&1 || true
    if [ -f /run/sshd.pid ]; then
        kill "$(cat /run/sshd.pid)" 2>/dev/null || true
    fi
    exit 0
}

# Count agents herdr still considers active. herdr runs as the agent user, so
# query it there. working/blocked/unknown keep the box alive; idle/done both
# mean "ready for input" (i.e. not doing anything), so they don't. A herdr that
# isn't up yet (before the first `herdr --remote` connect) counts as zero.
running_agents() {
    out=$(su - agent -c 'herdr agent list' 2>/dev/null) || { echo 0; return 0; }
    printf '%s' "$out" | jq '[.. | objects | select(has("state")) | .state]
        | map(select(. == "working" or . == "blocked" or . == "unknown")) | length' 2>/dev/null \
        || echo 0
}

# Established inbound connections on port 22 (an active SSH/herdr attach).
ssh_conns() {
    ss -Htn state established 'sport = :22' 2>/dev/null | wc -l | tr -d ' '
}

while :; do
    now=$(date +%s)
    age=$((now - boot))

    agents=$(running_agents)
    conns=$(ssh_conns)

    if [ "$age" -lt "$STARTUP_GRACE" ]; then
        state="grace"
    elif [ "${agents:-0}" -gt 0 ] || [ "${conns:-0}" -gt 0 ]; then
        state="busy"
    else
        state="idle"
    fi

    if [ "$state" = "idle" ]; then
        if [ -z "$idle_since" ]; then
            idle_since=$now
            log "idle (no active herdr agents, no ssh) — countdown to ${IDLE_TIMEOUT}s started"
        fi
        idle_for=$((now - idle_since))
        if [ "$idle_for" -ge "$IDLE_TIMEOUT" ]; then
            shutdown "idle for ${idle_for}s (>= ${IDLE_TIMEOUT}s)"
        fi
    elif [ -n "$idle_since" ]; then
        log "active again (${state}: agents=${agents} ssh=${conns}) — idle countdown reset"
        idle_since=""
    fi

    sleep "$IDLE_POLL_INTERVAL"
done
