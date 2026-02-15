# SKILL: Customer Spend Monitor

## Name
customer-spend-monitor

## Description
Daily customer revenue pace monitor. Compares current MTD revenue against prorated prior month for each customer, flags significant changes, and surfaces a watch list of customers with escalations or stale tickets. Posts alerts to Slack and/or Telegram.

## Schedule
Cron: `43 8 * * 2,4` (8:43 AM CT on Tuesdays and Thursdays)

## Commands
```bash
# Full run — posts to all configured channels
bash scripts/customer-spend-monitor.sh

# Dry run — calculate and print, don't post
bash scripts/customer-spend-monitor.sh --dry-run

# Save output to file
bash scripts/customer-spend-monitor.sh --output report.txt

# Single customer only
bash scripts/customer-spend-monitor.sh --customer "Ringba"

# Post to Slack only
bash scripts/customer-spend-monitor.sh --slack-only

# Post to Telegram only
bash scripts/customer-spend-monitor.sh --telegram-only
```

## Environment Variables
| Variable | Required | Description |
|----------|----------|-------------|
| `TABLEAU_PAT_SECRET` | Yes | Tableau Personal Access Token secret |
| `SLACK_BOT_TOKEN` | Yes* | Slack bot token with `chat:write` scope |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token (if using Telegram) |
| `CONFIG_PATH` | No | Path to config JSON (default: `./config/config.json`) |
| `DRY_RUN` | No | Set `true` to skip posting |

\* Required unless using `--telegram-only`

## Built-in Resilience
- **Config validation** at startup — catches missing/invalid settings early
- **Retry logic** — 3 attempts with exponential backoff on transient failures
- **Curl timeouts** — 10s connect, 30s max per request
- **Tableau fallback** — falls back to billing A2A agent if Tableau is unreachable
- **Dry-run mode** — preview output without posting

## Dependencies
- `bash`, `curl`, `jq`, `bc`
- Network access to Tableau Server
- Network access to `revenue-agents.query.prod.telnyx.io:8000` (fallback)

## Author
team-telnyx / CSM team

## Tags
revenue, monitoring, tableau, slack, telegram, cron, spend-tracking
