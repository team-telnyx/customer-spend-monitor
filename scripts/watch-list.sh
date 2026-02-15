#!/usr/bin/env bash
# Watch List Helper — checks escalation trackers and ENGDESK files
# Called by customer-spend-monitor.sh; outputs watch list lines to stdout
set -euo pipefail

CONFIG_PATH="${1:-./config/config.json}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  exit 0
fi

ESCALATION_PATH=$(jq -r '.escalation_tracker_path // ""' "$CONFIG_PATH")
ENGDESK_GLOB=$(jq -r '.engdesk_tracker_glob // ""' "$CONFIG_PATH")
THRESHOLD_ESCALATION=$(jq -r '.thresholds.escalation_count // 3' "$CONFIG_PATH")

OUTPUT=""

# --- Check escalation tracker ---
if [[ -n "$ESCALATION_PATH" && -f "$ESCALATION_PATH" ]]; then
  # Escalation tracker format: JSON with array of {customer, date, summary}
  # Count escalations per customer in the last 7 days
  SEVEN_DAYS_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d)

  # Get customers with >= threshold escalations in last 7 days
  escalation_results=$(jq -r --arg since "$SEVEN_DAYS_AGO" --argjson threshold "$THRESHOLD_ESCALATION" '
    [.[] | select(.date >= $since)]
    | group_by(.customer)
    | map({customer: .[0].customer, count: length, summaries: [.[].summary]})
    | map(select(.count >= $threshold))
    | .[]
    | "• \(.customer): \(.count) escalations this week (\(.summaries[:3] | join(", ")))"
  ' "$ESCALATION_PATH" 2>/dev/null) || true

  if [[ -n "$escalation_results" ]]; then
    OUTPUT+="${escalation_results}"
  fi
fi

# --- Check stale ENGDESK tickets ---
if [[ -n "$ENGDESK_GLOB" ]]; then
  # Look for ENGDESK ticket files and check age
  # Each file is JSON with {ticket_id, customer, created_date, status}
  STALE_THRESHOLD_DAYS=5  # business days ≈ 7 calendar days

  for ticket_file in $ENGDESK_GLOB; do
    [[ -f "$ticket_file" ]] || continue

    ticket_id=$(jq -r '.ticket_id // ""' "$ticket_file" 2>/dev/null) || continue
    customer=$(jq -r '.customer // ""' "$ticket_file" 2>/dev/null) || continue
    status=$(jq -r '.status // ""' "$ticket_file" 2>/dev/null) || continue
    created=$(jq -r '.created_date // ""' "$ticket_file" 2>/dev/null) || continue

    # Skip resolved tickets
    if [[ "$status" == "resolved" || "$status" == "closed" ]]; then
      continue
    fi

    # Calculate age in days
    if [[ -n "$created" ]]; then
      created_epoch=$(date -jf "%Y-%m-%d" "$created" +%s 2>/dev/null || date -d "$created" +%s 2>/dev/null || echo "0")
      now_epoch=$(date +%s)
      if [[ "$created_epoch" -gt 0 ]]; then
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
        # Rough business days: age * 5/7
        biz_days=$(( age_days * 5 / 7 ))
        if (( biz_days >= STALE_THRESHOLD_DAYS )); then
          if [[ -n "$OUTPUT" ]]; then
            OUTPUT+="\n"
          fi
          OUTPUT+="• ${customer}: ${ticket_id} stale (${biz_days} business days)"
        fi
      fi
    fi
  done
fi

if [[ -n "$OUTPUT" ]]; then
  echo -e "$OUTPUT"
fi
