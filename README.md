# Customer Spend Monitor

Daily spend alert system for Telnyx CSMs. Compares each customer's current-month revenue pace against prior month, flags significant changes, and surfaces a "Customers to Watch" list based on escalations, stale tickets, and vanishing line items.

## How It Works

For each customer, the tool:

1. **Pulls current MTD revenue** from Tableau (primary) or the billing A2A agent (fallback)
2. **Pulls prior month's total revenue** and prorates it to the same day number for fair comparison
3. **Calculates pace**: `change_pct = (current_mtd - prorated_prior) / prorated_prior × 100`
4. **Flags each customer**:
   - ✅ Growing 15%+ vs prior month pace
   - 🚨 Below -10% pace
   - ➖ Tracking normally
5. **For big movers (>50% change)**, pulls service-level breakdown to explain what's driving the change
6. **Builds a Watch List** from escalation trackers and stale ENGDESK tickets
7. **Posts** to Slack DM and/or Telegram

## Example Output

```
📊 Customer Spend Monitor — Feb 15

✅ Ringba: $425K (+8%) — on pace
🚨 Doximity: $3.7K (-94%) — $56K cliff from Jan
➖ Call Box: $71K (+1%) — tracking normally
✅ AudioCodes: $89K (+62%) — surging
🚨 Werkspot: $12K (-34%) — significant decline
➖ Nextiva: $201K (+3%) — tracking normally

📈 WHAT'S DRIVING THE CHANGES
High Growth (>50%):
• AudioCodes: Thailand Numbers +$12K (new deployment)

Watch List:
• Doximity: "user" line item vanished Jan→Feb ($56K/mo)

⚠️ CUSTOMERS TO WATCH
• AudioCodes: 3 escalations this week (503s, Seagate Thailand)
• Call Box: ENGDESK-49374 stale (8 business days)

Want to dig deeper into any of these? Just ask.
```

## Quick Start

### 1. Clone & Configure

```bash
git clone https://github.com/team-telnyx/telnyx-clawdbot-skills.git
cd telnyx-clawdbot-skills/skills/customer-spend-monitor

cp config/example-config.json config/config.json
# Edit config/config.json with your customer list and Tableau view IDs
```

### 2. Set Environment Variables

```bash
cp .env.example .env
# Edit .env:
#   TABLEAU_PAT_SECRET=your-personal-access-token-secret
#   SLACK_BOT_TOKEN=xoxb-your-token
#   TELEGRAM_BOT_TOKEN=your-telegram-bot-token  (optional)
#   CONFIG_PATH=./config/config.json
```

### 3. Run

```bash
# Full run — posts to all configured channels
bash scripts/customer-spend-monitor.sh

# Dry run — calculate and print, don't post anywhere
bash scripts/customer-spend-monitor.sh --dry-run

# Save output to file
bash scripts/customer-spend-monitor.sh --output report.txt

# Single customer
bash scripts/customer-spend-monitor.sh --customer "Ringba"

# Channel selection
bash scripts/customer-spend-monitor.sh --slack-only
bash scripts/customer-spend-monitor.sh --telegram-only
```

### 4. Schedule via OpenClaw Cron

See `docs/agent-instructions.md` for cron setup (recommended: Tue/Thu 8:43 AM CT).

## Data Sources

| Source | Priority | What It Provides |
|--------|----------|------------------|
| Tableau REST API | Primary | Monthly revenue views, daily granularity, service-level breakdown |
| Billing A2A Agent | Fallback | Current balance, usage data (less granular) |
| Escalation Tracker | Supplemental | Recent escalation counts per customer |
| ENGDESK Files | Supplemental | Stale engineering ticket detection |

### Tableau API Pattern

```
POST https://{server}/api/3.24/auth/signin
GET /api/3.24/sites/{siteId}/views/{viewId}/data?vf_Account+Name={name}
```

## Config File Format

See `config/example-config.json`. Key sections:

| Section | Description |
|---------|-------------|
| `customers[]` | Array of `{name, tableau_url_name, display_name}` |
| `tableau` | Server, site, PAT name, view IDs (monthly, daily, service_breakdown) |
| `slack.dm_channel` | Slack DM channel ID for alerts |
| `telegram.chat_id` | Telegram chat ID (optional) |
| `thresholds` | growth_pct, decline_pct, watch_drop_pct, escalation_count |
| `escalation_tracker_path` | Path to escalation tracker JSON |
| `engdesk_tracker_glob` | Glob pattern for ENGDESK ticket files |

## Features

- **Dual data source**: Tableau primary with billing A2A fallback
- **Prorated comparison**: Prior month revenue scaled to current day-of-month
- **Service-level drill-down**: Auto-explains big movers (>50% change)
- **Watch list integration**: Escalation trackers + stale ENGDESK tickets
- **Retry logic**: 3 attempts with exponential backoff on all HTTP requests
- **Curl timeouts**: 10s connect, 30s max per request
- **Config validation**: JSON structure and required fields checked at startup
- **Dry-run mode**: `--dry-run` flag or `DRY_RUN=true` env var
- **Output to file**: `--output <file>` for audit trail
- **Customer filter**: `--customer <name>` to check a single customer
- **Channel selection**: `--slack-only` or `--telegram-only`

## Requirements

- `bash`, `curl`, `jq`, `bc`
- Tableau Server access with a Personal Access Token
- Slack bot token with `chat:write` scope (for Slack posting)
- Telegram bot token (optional, for Telegram posting)
- OpenClaw (for automated cron scheduling)

## Security

- **No secrets in the repo.** All tokens via environment variables.
- **No customer data in the repo.** All customer info via local config file.
- `config/config.json` and `.env` are gitignored.
