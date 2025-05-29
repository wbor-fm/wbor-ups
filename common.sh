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

# Function to log to a specific file, prepending with a timestamp
# Usage: script_log "This is a message" "/var/log/wbor-ups/my_specific_log.log"
script_log() {
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
    local current_script_pid="$$" # PID of the script calling schedule_fifteen (e.g., onbattery)

    script_log "In schedule_fifteen (PID: $current_script_pid): About to launch background task. Script to exec: $script_to_exec" "/var/log/wbor-ups/$(basename "${BASH_SOURCE[1]}.log")"

    (
        # This subshell will have its own PID ($$)
        # Using a dedicated log for this subshell's journey
        local subshell_log_file="/var/log/wbor-ups/fifteen_subshell_debug.log"
        script_log "SUB-SHELL (PID $$) for fifteen: Starting. Will sleep 900 then exec '$script_to_exec'. My PGID: $(ps -o pgid= -p $$ --no-headers || echo 'pgid_lookup_failed'). My PPID: $PPID." "$subshell_log_file"

        sleep 900

        script_log "SUB-SHELL (PID $$) for fifteen: Sleep finished. About to exec '$script_to_exec'." "$subshell_log_file"
        # exec replaces the current shell with the new command.
        # The 'fifteen' script will need to set up its own logging via common.sh if it sources it.
        exec "$script_to_exec"
    ) &
    local pid_of_subshell=$! # PID of the subshell launched above

    local onbattery_log_file="/var/log/wbor-ups/onbattery.log" # Assuming schedule_fifteen is called by onbattery

    script_log "In schedule_fifteen (PID: $current_script_pid): Background task launched. PID CAPTURED for subshell (\$!): $pid_of_subshell" "$onbattery_log_file"
    script_log "In schedule_fifteen (PID: $current_script_pid): ps output for captured subshell PID $pid_of_subshell: [$(ps -o pid,ppid,pgid,sess,stat,args -p "$pid_of_subshell" --no-headers || echo "PID $pid_of_subshell not found by ps in schedule_fifteen")]" "$onbattery_log_file"

    if ! { echo "$pid_of_subshell" >"$pidfile"; } 2>/dev/null; then
        script_log "Warning: In schedule_fifteen (PID: $current_script_pid): Cannot write PID to $pidfile, falling back to /tmp" "$onbattery_log_file" >&2
        pidfile="/tmp/fifteen.pid" # Fallback, though ensure_dir_or_tmp should make original writable
        echo "$pid_of_subshell" >"$pidfile"
    fi
    chmod 600 "$pidfile"
    script_log "In schedule_fifteen (PID: $current_script_pid): PID $pid_of_subshell written to $pidfile" "$onbattery_log_file"
}

cancel_fifteen() {
    local run_dir="$1"
    local pidfile="$run_dir/fifteen.pid"
    local current_script_pid="$$"                                # PID of the script calling cancel_fifteen (e.g., offbattery)
    local offbattery_log_file="/var/log/wbor-ups/offbattery.log" # Assuming cancel_fifteen is called by offbattery

    script_log "In cancel_fifteen (PID: $current_script_pid): My PGID is $(ps -o pgid= -p $$ --no-headers || echo 'pgid_lookup_failed')" "$offbattery_log_file"

    if [[ -f "$pidfile" ]]; then
        local pid_to_kill
        pid_to_kill=$(cat "$pidfile")

        if [[ "$pid_to_kill" =~ ^[0-9]+$ && "$pid_to_kill" -gt 0 ]]; then
            script_log "In cancel_fifteen (PID: $current_script_pid): Valid PID $pid_to_kill read from $pidfile." "$offbattery_log_file"
            script_log "In cancel_fifteen (PID: $current_script_pid): STATUS BEFORE ANY KILL for target PID $pid_to_kill: [$(ps -o pid,ppid,pgid,sess,stat,args -p "$pid_to_kill" --no-headers || echo "Target PID $pid_to_kill not found by ps before kill")]" "$offbattery_log_file"

            local kill_output
            local kill_status
            local target_pgid
            target_pgid=$(ps -o pgid= -p "$pid_to_kill" --no-headers | tr -d ' ' || echo "pgid_lookup_failed_for_$pid_to_kill")

            if [[ "$target_pgid" =~ ^[0-9]+$ && "$target_pgid" -gt 0 && "$target_pgid" != "$pid_to_kill" ]]; then # Only if PGID is valid and different from PID
                script_log "In cancel_fifteen (PID: $current_script_pid): Target PID $pid_to_kill belongs to PGID $target_pgid. Attempting to kill PGID $target_pgid." "$offbattery_log_file"
                kill_output=$(kill -- -"$target_pgid" 2>&1)
                kill_status=$?
                if [[ $kill_status -eq 0 ]]; then
                    script_log "In cancel_fifteen (PID: $current_script_pid): Process group kill for PGID $target_pgid (of PID $pid_to_kill) SUCCEEDED. Output: [$kill_output]" "$offbattery_log_file"
                else
                    script_log "In cancel_fifteen (PID: $current_script_pid): Process group kill for PGID $target_pgid (of PID $pid_to_kill) FAILED (status: $kill_status). Output: [$kill_output]" "$offbattery_log_file"
                fi
            else
                script_log "In cancel_fifteen (PID: $current_script_pid): PGID for target PID $pid_to_kill is '$target_pgid'. Not attempting PGID kill or PGID is same as PID." "$offbattery_log_file"
            fi

            script_log "In cancel_fifteen (PID: $current_script_pid): Attempting direct SIGTERM kill for PID $pid_to_kill." "$offbattery_log_file"
            kill_output=$(kill "$pid_to_kill" 2>&1)
            kill_status=$?
            if [[ $kill_status -eq 0 ]]; then
                script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGTERM kill for PID $pid_to_kill SUCCEEDED (signal sent). Output: [$kill_output]" "$offbattery_log_file"
            else
                if [[ "$kill_output" == *"No such process"* ]]; then
                    script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGTERM kill for PID $pid_to_kill reported 'No such process' (status: $kill_status). Output: [$kill_output]" "$offbattery_log_file"
                else
                    script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGTERM kill for PID $pid_to_kill FAILED (status: $kill_status). Output: [$kill_output]" "$offbattery_log_file"
                fi
            fi

            sleep 0.2

            if ps -p "$pid_to_kill" >/dev/null; then
                script_log "In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill still exists after SIGTERM attempt. Attempting SIGKILL." "$offbattery_log_file"
                kill_output=$(kill -9 "$pid_to_kill" 2>&1)
                kill_status=$?
                if [[ $kill_status -eq 0 ]]; then
                    script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGKILL for PID $pid_to_kill SUCCEEDED (signal sent). Output: [$kill_output]" "$offbattery_log_file"
                else
                    if [[ "$kill_output" == *"No such process"* ]]; then
                        script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGKILL for PID $pid_to_kill reported 'No such process' (status: $kill_status). Output: [$kill_output]" "$offbattery_log_file"
                    else
                        script_log "In cancel_fifteen (PID: $current_script_pid): Direct SIGKILL for PID $pid_to_kill FAILED (status: $kill_status). Output: [$kill_output]" "$offbattery_log_file"
                    fi
                fi
            else
                script_log "In cancel_fifteen (PID: $current_script_pid): PID $pid_to_kill no longer exists after SIGTERM attempt (or was already gone). No SIGKILL needed." "$offbattery_log_file"
            fi

            sleep 0.2

            script_log "In cancel_fifteen (PID: $current_script_pid): STATUS AFTER ALL KILL ATTEMPTS for target PID $pid_to_kill: [$(ps -o pid,ppid,pgid,sess,stat,args -p "$pid_to_kill" --no-headers || echo "Target PID $pid_to_kill not found by ps after all kills")]" "$offbattery_log_file"

        elif [[ -n "$pid_to_kill" ]]; then
            script_log "In cancel_fifteen (PID: $current_script_pid): Warning: PID in $pidfile ('$pid_to_kill') is not a valid positive integer. No kill attempted." "$offbattery_log_file" >&2
        else
            script_log "In cancel_fifteen (PID: $current_script_pid): Warning: PID file $pidfile was empty or unreadable after initial check." "$offbattery_log_file" >&2
        fi

        if rm -f "$pidfile"; then
            script_log "In cancel_fifteen (PID: $current_script_pid): Removed $pidfile." "$offbattery_log_file"
        else
            script_log "In cancel_fifteen (PID: $current_script_pid): Failed to remove $pidfile (or it was already gone)." "$offbattery_log_file" >&2
        fi
    else
        script_log "In cancel_fifteen (PID: $current_script_pid): PID file $pidfile not found. No cancellation attempted." "$offbattery_log_file"
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
