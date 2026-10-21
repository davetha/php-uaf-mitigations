#!/bin/bash
# php-probe-loader.sh - manage the php-uaf probe stack (stap or bpftrace).
#
# Usage: php-probe-loader.sh {start|stop|status|restart} [options]
#   --tier 1|2|3     tier 1 (default): crash/payoff watchers, all workers.
#                    tier 2: + nested-unserialize reentrancy probe per PHP binary.
#                    tier 3: tier 2 with the SIGKILL blocker armed (read
#                    DETECTION.md first - tier 3 kills workers by design).
#   --engine E       stap or bpftrace; default: first available
#   --php PATH       with tier 2/3, probe only this PHP binary
#                    (default: auto-discover common cPanel/alt-php/lsphp paths)
#   --basedir DIR    probe script location (default: beside this loader)
#
# Probes write logs and pidfiles under /var/run/php-uaf-probes/.
# First stap start of a script compiles a kernel module (30-60s warmup).

set -u
BASE=$(cd "$(dirname "$0")" && pwd)
RUN=/var/run/php-uaf-probes
TIER=1
ENGINE=""
PHP=""
mkdir -p "$RUN"

CMD=${1:-}; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --tier) TIER=$2; shift 2 ;;
        --engine) ENGINE=$2; shift 2 ;;
        --php) PHP=$2; shift 2 ;;
        --basedir) BASE=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$ENGINE" ]; then
    command -v stap >/dev/null 2>&1 && ENGINE=stap || ENGINE=bpftrace
fi
command -v "$ENGINE" >/dev/null 2>&1 || { echo "no $ENGINE found" >&2; exit 3; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 4; }

probe_tier1() {
    case "$ENGINE" in
        stap)      stap -g "$BASE/stap/php-uaf-chain-detect.stp" ;;
        bpftrace)  bpftrace "$BASE/bpftrace/php-uaf-chain-detect.bt" ;;
    esac
}

discover_php() {
    local p
    for p in /usr/bin/php /usr/local/bin/php \
             /opt/alt/php*/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php \
             /usr/local/lsws/lsphp*/bin/lsphp; do
        [ -x "$p" ] && printf '%s\n' "$p"
    done
}

start_one() {
    local name=$1; shift
    local log="$RUN/$name.log" pidf="$RUN/$name.pid"
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
        echo "[skip] $name already running (pid $(cat "$pidf"))"
        return
    fi
    echo "[start] $name: $*"
    nohup "$@" >"$log" 2>&1 &
    echo $! >"$pidf"
}

do_start() {
    local log="$RUN/tier1-$ENGINE.log" pidf="$RUN/tier1-$ENGINE.pid"
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
        echo "[skip] tier1-$ENGINE already running (pid $(cat "$pidf"))"
    else
        echo "[start] tier1-$ENGINE"
        probe_tier1 >"$log" 2>&1 &
        echo $! >"$pidf"
    fi
    if [ "$TIER" -ge 2 ]; then
        local bins
        if [ -n "$PHP" ]; then bins=$PHP; else bins=$(discover_php); fi
        local b n
        for b in $bins; do
            n="reentry-$(echo "$b" | tr '/.' '__')"
            if [ "$TIER" -eq 3 ]; then
                start_one "$n" stap -g "$BASE/stap/php-unserialize-reentry-block.stp" "$b" -G MODE=2
            else
                start_one "$n" stap "$BASE/stap/php-unserialize-reentry-detect.stp" "$b"
            fi
        done
    fi
    echo "logs and pidfiles in $RUN; first stap run compiles (30-60s warmup)"
}

do_stop() {
    local f
    for f in "$RUN"/*.pid; do
        [ -f "$f" ] || continue
        if kill -0 "$(cat "$f")" 2>/dev/null; then
            echo "[stop] $(basename "$f" .pid) (pid $(cat "$f"))"
            kill "$(cat "$f")"
        fi
        rm -f "$f"
    done
}

do_status() {
    local f hits
    echo "engine=$ENGINE tier=$TIER basedir=$BASE"
    for f in "$RUN"/*.pid; do
        [ -f "$f" ] || continue
        if kill -0 "$(cat "$f")" 2>/dev/null; then
            hits=$(grep -cE 'REENTRY|CRASH-ORACLE|PAYOFF' "${f%.pid}.log" 2>/dev/null || true)
            echo "[run] $(basename "$f" .pid) pid $(cat "$f") alerts=${hits:-0}"
        else
            echo "[dead] $(basename "$f" .pid) (stale pidfile removed)"
            rm -f "$f"
        fi
    done
}

case "$CMD" in
    start)   do_start ;;
    stop)    do_stop ;;
    status)  do_status ;;
    restart) do_stop; sleep 1; do_start ;;
    *) echo "usage: $0 {start|stop|status|restart} [--tier 1|2|3] [--engine stap|bpftrace] [--php /path/php] [--basedir dir]" >&2; exit 2 ;;
esac
