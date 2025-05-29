#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail -o errtrace
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

# Function to log to a specific file, prepending with a timestamp
# Usage: script_log "This is a message" "/var/log/wbor-ups/my_specific_log.log"
# Note: This assumes the calling script (onbattery, offbattery) has already called setup_logging
# OR it's used for logs that might occur before setup_logging (like in fifteen_subshell_debug.log, which we removed for prod)
# For production, most logging will come from setup_logging's tee for the main script logs.
# This function will effectively just echo if STDOUT is already redirected by setup_logging.
_script_log_to_file() {
    local message="$1"
    local log_file="$2"
    echo "[$(timestamp)] $message" >>"$log_file"
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
    # If xtrace is enabled, it will also go to the logfile.
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
    local run_dir="$1" script_to_exec="$2"
    local pidfile="$run_dir/fifteen.pid"
    # Assuming setup_logging has been called by the parent script (e.g., onbattery)
    echo "[$(timestamp)] In schedule_fifteen (PID: $$): Scheduling '$script_to_exec'."

    (
        # This subshell runs in the background. No verbose logging from here in production.
        sleep 900
        exec "$script_to_exec"
    ) &
    local pid_of_subshell=$!

    echo "[$(timestamp)] In schedule_fifteen (PID: $$): Background task for '$script_to_exec' launched with PID $pid_of_subshell."

    if ! { echo "$pid_of_subshell" >"$pidfile"; } 2>/dev/null; then
        echo "[$(timestamp)] Warning: In schedule_fifteen (PID: $$): Cannot write PID to $pidfile, falling back to /tmp" >&2
        pidfile="/tmp/fifteen.pid"
        echo "$pid_of_subshell" >"$pidfile"
    fi
    chmod 600 "$pidfile"
    echo "[$(timestamp)] In schedule_fifteen (PID: $$): PID $pid_of_subshell written to $pidfile."
}

cancel_fifteen() {
    local run_dir="$1"
    local pidfile="$run_dir/fifteen.pid"
    local current_script_pid="$$"
    # Assuming setup_logging has been called by the parent script (e.g., offbattery)

    echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): Checking for PID file $pidfile."

    if [[ -f "$pidfile" ]]; then
        local pid_to_kill
        pid_to_kill=$(cat "$pidfile")

        if [[ "$pid_to_kill" =~ ^[0-9]+$ && "$pid_to_kill" -gt 0 ]]; then
            echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): Attempting to cancel PID $pid_to_kill (read from $pidfile)."

            local kill_output
            local kill_status

            echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): Attempting SIGTERM kill for PID $pid_to_kill."
            # Try SIGTERM first
            if kill "$pid_to_kill" 2>/dev/null; then # Silently try to kill
                echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): SIGTERM sent to PID $pid_to_kill."
            else
                # If kill returns error, check if process is already gone
                if ! ps -p "$pid_to_kill" >/dev/null; then
                    echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill already gone before/during SIGTERM attempt."
                else                                        # Process exists, but kill command failed for other reason
                    kill_output=$(kill "$pid_to_kill" 2>&1) # Capture error output this time
                    echo "[$(timestamp)] Warning: In cancel_fifteen (PID: $current_script_pid): SIGTERM failed for PID $pid_to_kill but process still exists. Error: [$kill_output]" >&2
                fi
            fi

            sleep 0.2 # Give SIGTERM a moment

            if ps -p "$pid_to_kill" >/dev/null; then # Check if process still exists
                echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill still exists after SIGTERM attempt. Attempting SIGKILL."
                if kill -9 "$pid_to_kill" 2>/dev/null; then # Silently try SIGKILL
                    echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): SIGKILL sent to PID $pid_to_kill."
                else
                    # If SIGKILL returns error, check if process is already gone
                    if ! ps -p "$pid_to_kill" >/dev/null; then
                        echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill gone during/after SIGKILL attempt."
                    else                                           # Process exists, but SIGKILL command failed (highly unusual)
                        kill_output=$(kill -9 "$pid_to_kill" 2>&1) # Capture error
                        echo "[$(timestamp)] ERROR: In cancel_fifteen (PID: $current_script_pid): SIGKILL FAILED for PID $pid_to_kill. Manual intervention may be needed. Error: [$kill_output]" >&2
                    fi
                fi
            else
                echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill successfully terminated by SIGTERM (or was already gone)."
            fi

        elif [[ -n "$pid_to_kill" ]]; then
            echo "[$(timestamp)] Warning: In cancel_fifteen (PID: $current_script_pid): PID in $pidfile ('$pid_to_kill') is not a valid positive integer. No kill attempted." >&2
        else
            echo "[$(timestamp)] Warning: In cancel_fifteen (PID: $current_script_pid): PID file $pidfile was empty or unreadable." >&2
        fi

        # Always remove the pidfile if it existed
        if rm -f "$pidfile"; then
            echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): Removed $pidfile."
        else
            # This case should ideally not happen if -f was true, but good to be defensive.
            echo "[$(timestamp)] Warning: In cancel_fifteen (PID: $current_script_pid): Failed to remove $pidfile (or it was already gone)." >&2
        fi
    else
        echo "[$(timestamp)] In cancel_fifteen (PID: $current_script_pid): PID file $pidfile not found. No cancellation attempted."
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
