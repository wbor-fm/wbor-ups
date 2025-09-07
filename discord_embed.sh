#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail -o errtrace

: "${DISCORD_WEBHOOK_URL:?Need to set DISCORD_WEBHOOK_URL}"

# Usage: send_discord_embed <title> <description> <fields_json> [<color>]
send_discord_embed() {
  local title=$1 desc=$2 fields_json=$3 color=${4:-16711680}
  local ts payload http_code
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Construct JSON payload
  payload=$(
    cat <<EOF
{
  "username": "UPS Monitor",
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "timestamp": "$ts",
    "fields": $fields_json,
    "footer": {
      "text": "Powered by wbor-fm/wbor-ups"
    }
  }]
}
EOF
  )

  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$DISCORD_WEBHOOK_URL")

  if [[ $http_code -ne 200 && $http_code -ne 204 ]]; then
    echo "Warning: Discord webhook returned HTTP $http_code" >&2
  fi
}
