#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

: "${GROUPME_API_URL:?Need GROUPME_API_URL}"
: "${MGMT_BOT_ID:?Need MGMT_BOT_ID}"
: "${CLUBWIDE_BOT_ID:?Need CLUBWIDE_BOT_ID}"

# Management bot
groupme_mgmt() {
    local text="$1"
    curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$GROUPME_API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"text\":\"$text\",\"bot_id\":\"$MGMT_BOT_ID\"}"
}

# Club-wide bot
groupme_club() {
    local text="$1"
    curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$GROUPME_API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"text\":\"$text\",\"bot_id\":\"$CLUBWIDE_BOT_ID\"}"
}
