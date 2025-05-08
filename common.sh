#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail -o errtrace -o xtrace
trap 'echo >&2 "[$BASH_SOURCE:$LINENO] Error $? : exiting"; exit 1' ERR

: "${FROM_EMAIL:?Need FROM_EMAIL}" "${SYSADMIN:?Need SYSADMIN}"
: "${APCUPSD_MAIL:?Need APCUPSD_MAIL}"

# common.sh — shared utilities for wbor-ups scripts

# ensure a directory exists (700 perms) or fall back to /tmp
# Usage: dir=$(ensure_dir_or_tmp "/var/run/wbor-ups")
ensure_dir_or_tmp() {
    local target="$1"
    if mkdir -p "$target" 2>/dev/null; then
        chmod 700 "$target"
        printf "%s" "$target"
    else
        echo "Warning: Cannot create directory $target, falling back to /tmp" >&2
        printf "/tmp"
    fi
}

# initialize logging: point STDOUT/ERR through tee to a logfile, with fallback
# Usage: setup_logging "/var/log/wbor-ups/onbattery.log"
setup_logging() {
    local logfile="$1"
    local logdir
    logdir="$(dirname "$logfile")"
    if ! mkdir -p "$logdir" 2>/dev/null; then
        echo "Warning: Cannot write logs to $logdir, falling back to /tmp" >&2
        logfile="/tmp/$(basename "$logfile")"
        mkdir -p "$(dirname "$logfile")"
    fi
    exec > >(tee -a "$logfile") 2>&1
}

# safe-read TIMELEFT from apcaccess (give "Unavailable" on fail/timeout)
get_timeleft() {
    local tl
    if tl="$(timeout 5 sudo apcaccess -p TIMELEFT 2>/dev/null)"; then
        printf "%s" "${tl:-Unavailable}"
    else
        printf "Unavailable"
    fi
}

# schedule or cancel the 15-minute followup
# Usage: schedule_fifteen "/var/run/wbor-ups" "/etc/apcupsd/fifteen"
schedule_fifteen() {
    local run_dir="$1" script="$2"
    local pidfile="$run_dir/fifteen.pid"
    (
        sleep 900
        exec "$script"
    ) &
    local pid=$!
    if ! { echo "$pid" >"$pidfile"; } 2>/dev/null; then
        echo "Warning: Cannot write PID to $pidfile, falling back to /tmp" >&2
        pidfile="/tmp/fifteen.pid"
        echo "$pid" >"$pidfile"
    fi
    chmod 600 "$pidfile"
}

cancel_fifteen() {
    local run_dir="$1"
    local pidfile="$run_dir/fifteen.pid"
    if [[ -f "$pidfile" ]]; then
        kill "$(cat "$pidfile")" &>/dev/null || true
        rm -f "$pidfile"
    fi
}

send_email() {
    local subject="$1"
    local body="$2"

    {
        echo "To: $SYSADMIN"
        echo "From: $FROM_EMAIL"
        echo "Subject: $subject"
        echo ""
        echo -e "$body"
    } | sudo "$APCUPSD_MAIL" "$SYSADMIN" ||
        echo "Warning: email send failed for '$subject'" >&2
}
