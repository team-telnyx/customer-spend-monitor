# Customer Spend Monitor — Agent Instructions

## Purpose
Run the customer spend monitor on a regular schedule and post alerts to Slack and/or Telegram.

## Cron Setup
Schedule: `43 8 * * 2,4` (8:43 AM CT on Tuesdays and Thursdays)

### OpenClaw Cron Command
```
cd ~/clawd/skills/customer-spend-monitor && source .env && bash scripts/customer-spend-monitor.sh
```

## What It Does
1. Reads customer list from `config/config.json`
2. Authenticates to Tableau REST API with PAT
3. Pulls current MTD and prior month revenue per customer
4. Prorates prior month to current day number for fair comparison
5. Flags customers by pace: ✅ growing, 🚨 declining, ➖ normal
6. For big movers (>50%), pulls service-level breakdown
7. Runs watch-list checks (escalations, stale ENGDESK tickets)
8. Posts formatted alert to Slack DM and/or Telegram

## Required Environment
- `TABLEAU_PAT_SECRET` — Tableau PAT secret
- `SLACK_BOT_TOKEN` — Bot token with `chat:write` scope
- `TELEGRAM_BOT_TOKEN` — Telegram bot token (optional)
- `CONFIG_PATH` — Path to config JSON (defaults to `./config/config.json`)

## Troubleshooting
- **Tableau auth fails**: Check PAT name/secret, verify PAT hasn't expired
- **Fallback to A2A**: If Tableau is down, the script auto-falls back to the billing A2A agent (less granular)
- **Empty data**: Verify `tableau_url_name` matches exactly what Tableau expects (URL-encoded)
- **Slack post fails**: Verify bot token and that the bot has access to the DM channel
- **Watch list empty**: Check `escalation_tracker_path` and `engdesk_tracker_glob` paths in config
