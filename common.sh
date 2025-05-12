#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail -o errtrace -o xtrace
trap 'echo >&2 "[$BASH_SOURCE:$LINENO] Error $? : exiting"; exit 1' ERR

: "${FROM_EMAIL:?Need FROM_EMAIL}" "${SYSADMIN:?Need SYSADMIN}"
: "${APCUPSD_MAIL:?Need APCUPSD_MAIL}"
: "${UPSNAME:?Need UPSNAME}" # UPSNAME is used in publish_rabbitmq_event

# RabbitMQ specific variables
: "${RABBITMQ_URL:?Need to set RABBITMQ_URL}"
: "${RABBITMQ_EXCHANGE:?Need to set RABBITMQ_EXCHANGE}"

# common.sh — shared utilities for wbor-ups scripts

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

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
    local subject="$1" body="$2" from="${3:-$FROM_EMAIL}"

    {
        echo "To: $SYSADMIN"
        echo "From: $from"
        echo "Subject: $subject"
        echo ""
        echo -e "$body"
    } | sudo $APCUPSD_MAIL "$SYSADMIN"
}

# Publish event to RabbitMQ
# Usage: publish_rabbitmq_event <routing_key> <event_type> <hostname_val> <json_extra_data_fields>
# json_extra_data_fields should be a comma-separated list of "key":"value" JSON strings, or empty.
# Example: '"field1":"value1","field2":"value2"'
publish_rabbitmq_event() {
    local routing_key="$1"
    local event_type="$2"
    local hostname_val="$3" # Pass hostname explicitly
    local json_extra_data_fields="$4"
    local ts_utc payload

    ts_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ") # ISO 8601 UTC timestamp

    local common_fields='"ups_name":"'"$UPSNAME"'","hostname":"'"$hostname_val"'","timestamp_utc":"'"$ts_utc"'","event_type":"'"$event_type"'","routing_key":"'"$routing_key"'"'

    local data_object_content
    if [[ -n "$json_extra_data_fields" ]]; then
        data_object_content="$json_extra_data_fields"
    else
        data_object_content="" # Empty if no extra fields
    fi

    payload='{'${common_fields}',"data":{'"$data_object_content"'}}'

    echo "[$(timestamp)] Publishing to RabbitMQ. Exchange: '$RABBITMQ_EXCHANGE', RoutingKey: '$routing_key', Payload: $payload"

    # Use a subshell to avoid script exit if amqp-publish fails and errexit is set
    (
        amqp-publish -u "$RABBITMQ_URL" \
            -e "$RABBITMQ_EXCHANGE" \
            -r "$routing_key" \
            -p \
            --content-type="application/json" \
            --body="$payload"
    )
    local publish_status=$?

    if [[ $publish_status -eq 0 ]]; then
        echo "[$(timestamp)] Successfully published event '$event_type' to RabbitMQ."
    else
        echo "[$(timestamp)] Warning: Failed to publish event '$event_type' to RabbitMQ. amqp-publish exit code: $publish_status" >&2
        # Could add more robust error handling here, like retries or specific error messages based on amqp-publish output.
    fi
}
