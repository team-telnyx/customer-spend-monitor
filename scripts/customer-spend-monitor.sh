#!/usr/bin/env bash
# Customer Spend Monitor — compares current MTD revenue pace vs prior month
# Posts alerts to Slack and/or Telegram
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Flags ---
OUTPUT_FILE=""
DRY_RUN="${DRY_RUN:-false}"
FILTER_CUSTOMER=""
SLACK_ONLY=false
TELEGRAM_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --customer) FILTER_CUSTOMER="$2"; shift 2 ;;
    --slack-only) SLACK_ONLY=true; shift ;;
    --telegram-only) TELEGRAM_ONLY=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"

# --- Preflight checks ---
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found at $CONFIG_PATH" >&2
  echo "Copy config/example-config.json to config/config.json and fill in your data." >&2
  exit 1
fi

for cmd in jq curl bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required. Install with: brew install $cmd" >&2
    exit 1
  fi
done

# --- Config validation ---
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
  echo "ERROR: $CONFIG_PATH is not valid JSON" >&2
  exit 1
fi

missing_fields=()
if [[ "$(jq 'has("customers") and (.customers | type == "array")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("customers (array)")
fi
if [[ "$(jq 'has("tableau") and (.tableau | (has("server") and has("pat_name") and has("views")))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("tableau (server, pat_name, views)")
fi
if [[ "$(jq 'has("slack") and (.slack | has("dm_channel"))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("slack.dm_channel")
fi
if [[ ${#missing_fields[@]} -gt 0 ]]; then
  echo "ERROR: Config missing required fields: ${missing_fields[*]}" >&2
  exit 1
fi

# --- Load config ---
TABLEAU_SERVER=$(jq -r '.tableau.server' "$CONFIG_PATH")
TABLEAU_SITE=$(jq -r '.tableau.site // ""' "$CONFIG_PATH")
TABLEAU_PAT_NAME=$(jq -r '.tableau.pat_name' "$CONFIG_PATH")
TABLEAU_API_VERSION=$(jq -r '.tableau.api_version // "3.24"' "$CONFIG_PATH")
VIEW_MONTHLY=$(jq -r '.tableau.views.monthly_revenue' "$CONFIG_PATH")
VIEW_DAILY=$(jq -r '.tableau.views.daily_revenue' "$CONFIG_PATH")
VIEW_SERVICE=$(jq -r '.tableau.views.service_breakdown // ""' "$CONFIG_PATH")

SLACK_CHANNEL=$(jq -r '.slack.dm_channel' "$CONFIG_PATH")
TELEGRAM_CHAT_ID=$(jq -r '.telegram.chat_id // ""' "$CONFIG_PATH")

THRESHOLD_GROWTH=$(jq -r '.thresholds.growth_pct // 15' "$CONFIG_PATH")
THRESHOLD_DECLINE=$(jq -r '.thresholds.decline_pct // -10' "$CONFIG_PATH")
THRESHOLD_WATCH_DROP=$(jq -r '.thresholds.watch_drop_pct // -25' "$CONFIG_PATH")
THRESHOLD_ESCALATION=$(jq -r '.thresholds.escalation_count // 3' "$CONFIG_PATH")

A2A_URL=$(jq -r '.a2a.billing_url // "http://revenue-agents.query.prod.telnyx.io:8000/a2a/billing-account/rpc"' "$CONFIG_PATH")

CUSTOMER_COUNT=$(jq '.customers | length' "$CONFIG_PATH")

# --- Date calculations ---
TODAY=$(date +%d | sed 's/^0//')
CURRENT_MONTH=$(date +%Y-%m)
PRIOR_MONTH=$(date -v-1m +%Y-%m 2>/dev/null || date -d "last month" +%Y-%m)
PRIOR_MONTH_DAYS=$(date -v-1m -v1d -v+1m -v-1d +%d 2>/dev/null | sed 's/^0//' || cal "$(date -d 'last month' +%m)" "$(date -d 'last month' +%Y)" | awk 'NF {DAYS = $NF}; END {print DAYS}')
DATE_LABEL=$(date +"%b %d")

# --- Retry wrapper ---
retry_curl() {
  local attempt=1 max=3 delay=2
  while true; do
    local http_code output
    output=$(curl --connect-timeout 10 --max-time 30 -s -w "\n%{http_code}" "$@" 2>/dev/null) || true
    http_code=$(echo "$output" | tail -1)
    local body
    body=$(echo "$output" | sed '$d')

    if [[ "$http_code" =~ ^2 ]]; then
      echo "$body"
      return 0
    fi

    if [[ $attempt -ge $max ]]; then
      echo "$body"
      return 1
    fi
    echo "  Retry $attempt/$max after ${delay}s (HTTP $http_code)..." >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# --- Tableau Auth ---
TABLEAU_TOKEN=""
TABLEAU_SITE_ID=""
TABLEAU_AVAILABLE=false

tableau_auth() {
  if [[ -z "${TABLEAU_PAT_SECRET:-}" ]]; then
    echo "WARNING: TABLEAU_PAT_SECRET not set, will use A2A fallback" >&2
    return 1
  fi

  local auth_payload
  auth_payload=$(jq -n \
    --arg name "$TABLEAU_PAT_NAME" \
    --arg secret "$TABLEAU_PAT_SECRET" \
    --arg site "$TABLEAU_SITE" \
    '{credentials: {personalAccessTokenName: $name, personalAccessTokenSecret: $secret, site: {contentUrl: $site}}}')

  local response
  response=$(retry_curl -X POST \
    "https://${TABLEAU_SERVER}/api/${TABLEAU_API_VERSION}/auth/signin" \
    -H "Content-Type: application/json" \
    -d "$auth_payload") || { echo "WARNING: Tableau auth failed, using A2A fallback" >&2; return 1; }

  TABLEAU_TOKEN=$(echo "$response" | jq -r '.credentials.token // empty')
  TABLEAU_SITE_ID=$(echo "$response" | jq -r '.credentials.site.id // empty')

  if [[ -z "$TABLEAU_TOKEN" ]]; then
    echo "WARNING: Tableau auth returned no token, using A2A fallback" >&2
    return 1
  fi

  TABLEAU_AVAILABLE=true
  echo "✓ Tableau authenticated" >&2
  return 0
}

# --- Tableau data fetch ---
tableau_view_data() {
  local view_id="$1" filter_name="$2" filter_value="$3"
  if [[ "$TABLEAU_AVAILABLE" != "true" ]]; then return 1; fi

  local url="https://${TABLEAU_SERVER}/api/${TABLEAU_API_VERSION}/sites/${TABLEAU_SITE_ID}/views/${view_id}/data"
  if [[ -n "$filter_name" && -n "$filter_value" ]]; then
    url="${url}?vf_${filter_name}=${filter_value}"
  fi

  retry_curl -H "X-Tableau-Auth: ${TABLEAU_TOKEN}" "$url" || return 1
}

# --- A2A fallback query ---
a2a_query() {
  local msg_id="$1" query="$2"
  local payload
  payload=$(jq -n \
    --arg mid "$msg_id" \
    --arg query "$query" \
    '{
      jsonrpc: "2.0",
      id: $mid,
      method: "message/send",
      params: {
        message: {
          messageId: $mid,
          role: "user",
          parts: [{ kind: "text", text: $query }]
        }
      }
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would query A2A: $query" >&2
    echo ""
    return 0
  fi

  local response
  response=$(retry_curl -X POST "$A2A_URL" \
    -H "Content-Type: application/json" \
    -d "$payload") || { echo ""; return 1; }

  echo "$response" | jq -r '
    .result.artifacts[0].parts[0].text //
    .result.message.parts[0].text //
    .result.parts[0].text //
    empty' 2>/dev/null || echo ""
}

# --- Extract dollar amount from text/CSV ---
extract_revenue() {
  local text="$1"
  # Try to find a dollar amount; handles $1,234.56 or 1234.56
  echo "$text" | grep -oE '[-]?\$?[0-9,]+\.?[0-9]*' | head -1 | tr -d '$,' || echo "0"
}

# --- Format dollar amount for display ---
format_dollars() {
  local amount="$1"
  local abs_amount
  abs_amount=$(echo "$amount" | tr -d '-')
  if (( $(echo "$abs_amount >= 1000000" | bc -l) )); then
    printf "\$%.1fM" "$(echo "$amount / 1000000" | bc -l)"
  elif (( $(echo "$abs_amount >= 1000" | bc -l) )); then
    printf "\$%.0fK" "$(echo "$amount / 1000" | bc -l)"
  else
    printf "\$%.1fK" "$(echo "$amount / 1000" | bc -l)"
  fi
}

# --- Get revenue for a customer (Tableau primary, A2A fallback) ---
get_customer_revenue() {
  local customer_name="$1" tableau_url_name="$2" month="$3"

  # Try Tableau first
  if [[ "$TABLEAU_AVAILABLE" == "true" ]]; then
    local data
    data=$(tableau_view_data "$VIEW_MONTHLY" "Account+Name" "$tableau_url_name" 2>/dev/null) || true
    if [[ -n "$data" ]]; then
      # Parse Tableau CSV/JSON response for the target month
      local revenue
      revenue=$(echo "$data" | grep -i "$month" | head -1 | grep -oE '[0-9,]+\.?[0-9]*' | tail -1 || echo "")
      if [[ -n "$revenue" ]]; then
        echo "$revenue" | tr -d ','
        return 0
      fi
    fi
  fi

  # Fallback to A2A
  local ts
  ts=$(date +%s)
  local response
  response=$(a2a_query "spend-${ts}-${customer_name}" \
    "What is the total revenue for ${customer_name} for month ${month}?")
  extract_revenue "$response"
}

# --- Get daily revenue data for prorating ---
get_daily_data() {
  local customer_name="$1" tableau_url_name="$2"

  if [[ "$TABLEAU_AVAILABLE" == "true" ]]; then
    local data
    data=$(tableau_view_data "$VIEW_DAILY" "Account+Name" "$tableau_url_name" 2>/dev/null) || true
    if [[ -n "$data" ]]; then
      echo "$data"
      return 0
    fi
  fi
  echo ""
}

# --- Get service-level breakdown for big movers ---
get_service_breakdown() {
  local customer_name="$1" tableau_url_name="$2"

  if [[ "$TABLEAU_AVAILABLE" == "true" && -n "$VIEW_SERVICE" ]]; then
    local data
    data=$(tableau_view_data "$VIEW_SERVICE" "Account+Name" "$tableau_url_name" 2>/dev/null) || true
    if [[ -n "$data" ]]; then
      echo "$data"
      return 0
    fi
  fi
  echo ""
}

# ============================================================
# MAIN
# ============================================================

echo "📊 Customer Spend Monitor starting..." >&2
echo "   Date: $DATE_LABEL | Day $TODAY of month" >&2
echo "   Prior month: $PRIOR_MONTH ($PRIOR_MONTH_DAYS days)" >&2
echo "   Customers: $CUSTOMER_COUNT" >&2
echo "" >&2

# Authenticate to Tableau
if [[ "$DRY_RUN" != "true" ]]; then
  tableau_auth || true
fi

# --- Process each customer ---
declare -a LINES=()
declare -a DRIVERS=()
declare -a WATCH_ITEMS=()

for i in $(seq 0 $((CUSTOMER_COUNT - 1))); do
  name=$(jq -r ".customers[$i].name" "$CONFIG_PATH")
  tableau_url_name=$(jq -r ".customers[$i].tableau_url_name" "$CONFIG_PATH")
  display_name=$(jq -r ".customers[$i].display_name" "$CONFIG_PATH")

  # Filter if --customer specified
  if [[ -n "$FILTER_CUSTOMER" && "$name" != "$FILTER_CUSTOMER" && "$display_name" != "$FILTER_CUSTOMER" ]]; then
    continue
  fi

  echo "  Processing $display_name..." >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    LINES+=("➖ $display_name: \$0 (0%) — [DRY RUN]")
    continue
  fi

  # Get current MTD revenue
  current_mtd=$(get_customer_revenue "$name" "$tableau_url_name" "$CURRENT_MONTH")
  current_mtd="${current_mtd:-0}"

  # Get prior month total revenue
  prior_total=$(get_customer_revenue "$name" "$tableau_url_name" "$PRIOR_MONTH")
  prior_total="${prior_total:-0}"

  # Prorate prior month to current day
  if (( $(echo "$prior_total > 0 && $PRIOR_MONTH_DAYS > 0" | bc -l) )); then
    prorated_prior=$(echo "scale=2; $prior_total * $TODAY / $PRIOR_MONTH_DAYS" | bc -l)
  else
    prorated_prior="0"
  fi

  # Calculate change percentage
  if (( $(echo "$prorated_prior > 0" | bc -l) )); then
    change_pct=$(echo "scale=1; ($current_mtd - $prorated_prior) / $prorated_prior * 100" | bc -l)
  elif (( $(echo "$current_mtd > 0" | bc -l) )); then
    change_pct="999"
  else
    change_pct="0"
  fi

  # Round for display
  change_pct_int=$(printf "%.0f" "$change_pct")
  formatted_amount=$(format_dollars "$current_mtd")

  # Determine emoji and status
  if (( change_pct_int >= THRESHOLD_GROWTH )); then
    emoji="✅"
    if (( change_pct_int >= 50 )); then
      status="surging"
    else
      status="on pace"
    fi
  elif (( change_pct_int <= ${THRESHOLD_DECLINE#-} * -1 )); then
    emoji="🚨"
    if (( change_pct_int <= -50 )); then
      prior_formatted=$(format_dollars "$prior_total")
      status="${prior_formatted} cliff from $(date -v-1m +%b 2>/dev/null || date -d 'last month' +%b)"
    else
      status="significant decline"
    fi
  else
    emoji="➖"
    status="tracking normally"
  fi

  # Sign for display
  if (( change_pct_int >= 0 )); then
    sign="+"
  else
    sign=""
  fi

  LINES+=("${emoji} ${display_name}: ${formatted_amount} (${sign}${change_pct_int}%) — ${status}")

  # --- Big movers: get service-level breakdown ---
  abs_change=${change_pct_int#-}
  if (( abs_change > 50 )); then
    breakdown=$(get_service_breakdown "$name" "$tableau_url_name")
    if [[ -n "$breakdown" ]]; then
      # Parse top contributing service from breakdown
      # This is a simplified parse; real data would need column mapping
      top_service=$(echo "$breakdown" | head -5 | tail -1 || echo "")
      if [[ -n "$top_service" ]]; then
        if (( change_pct_int > 50 )); then
          DRIVERS+=("High Growth (>50%):")
          DRIVERS+=("• ${display_name}: ${top_service}")
        else
          DRIVERS+=("Watch List:")
          DRIVERS+=("• ${display_name}: ${top_service}")
        fi
      fi
    fi
  fi

  # --- Check for watch-drop threshold ---
  if (( change_pct_int <= ${THRESHOLD_WATCH_DROP#-} * -1 )); then
    WATCH_ITEMS+=("${display_name}: ${change_pct_int}% MoM drop — needs attention")
  fi
done

# --- Watch list from escalation tracker and ENGDESK ---
WATCH_LIST_OUTPUT=""
if [[ -f "${SCRIPT_DIR}/watch-list.sh" ]]; then
  WATCH_LIST_OUTPUT=$(bash "${SCRIPT_DIR}/watch-list.sh" "$CONFIG_PATH" 2>/dev/null || echo "")
fi

# --- Build final message ---
MSG="📊 Customer Spend Monitor — ${DATE_LABEL}"
MSG+="\n"

for line in "${LINES[@]}"; do
  MSG+="\n${line}"
done

if [[ ${#DRIVERS[@]} -gt 0 ]]; then
  MSG+="\n\n📈 WHAT'S DRIVING THE CHANGES"
  for driver in "${DRIVERS[@]}"; do
    MSG+="\n${driver}"
  done
fi

if [[ -n "$WATCH_LIST_OUTPUT" || ${#WATCH_ITEMS[@]} -gt 0 ]]; then
  MSG+="\n\n⚠️ CUSTOMERS TO WATCH"
  for item in "${WATCH_ITEMS[@]}"; do
    MSG+="\n• ${item}"
  done
  if [[ -n "$WATCH_LIST_OUTPUT" ]]; then
    MSG+="\n${WATCH_LIST_OUTPUT}"
  fi
fi

MSG+="\n\nWant to dig deeper into any of these? Just ask."

# --- Output ---
FORMATTED_MSG=$(echo -e "$MSG")

echo "$FORMATTED_MSG" >&2

# Save to file if requested
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$FORMATTED_MSG" > "$OUTPUT_FILE"
  echo "📁 Saved to $OUTPUT_FILE" >&2
fi

# --- Post to Slack ---
if [[ "$DRY_RUN" != "true" && "$TELEGRAM_ONLY" != "true" && -n "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "Posting to Slack..." >&2
  slack_payload=$(jq -n \
    --arg channel "$SLACK_CHANNEL" \
    --arg text "$FORMATTED_MSG" \
    '{channel: $channel, text: $text, unfurl_links: false}')

  slack_response=$(retry_curl -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$slack_payload") || echo "WARNING: Slack post failed" >&2

  if echo "$slack_response" | jq -e '.ok == true' &>/dev/null; then
    echo "✓ Posted to Slack" >&2
  else
    echo "WARNING: Slack post failed: $(echo "$slack_response" | jq -r '.error // "unknown"')" >&2
  fi
elif [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] Would post to Slack channel $SLACK_CHANNEL" >&2
fi

# --- Post to Telegram ---
if [[ "$DRY_RUN" != "true" && "$SLACK_ONLY" != "true" && -n "${TELEGRAM_BOT_TOKEN:-}" && -n "$TELEGRAM_CHAT_ID" ]]; then
  echo "Posting to Telegram..." >&2
  tg_payload=$(jq -n \
    --arg chat_id "$TELEGRAM_CHAT_ID" \
    --arg text "$FORMATTED_MSG" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML"}')

  tg_response=$(retry_curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$tg_payload") || echo "WARNING: Telegram post failed" >&2

  if echo "$tg_response" | jq -e '.ok == true' &>/dev/null; then
    echo "✓ Posted to Telegram" >&2
  else
    echo "WARNING: Telegram post failed: $(echo "$tg_response" | jq -r '.description // "unknown"')" >&2
  fi
elif [[ "$DRY_RUN" == "true" && -n "$TELEGRAM_CHAT_ID" ]]; then
  echo "[DRY RUN] Would post to Telegram chat $TELEGRAM_CHAT_ID" >&2
fi

echo "✅ Customer Spend Monitor completed: ${#LINES[@]} customers processed" >&2
