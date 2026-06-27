#!/usr/bin/env bash
# Prune GitHub-notification binders older than 14 days.
# Wired by [cron.gh_notif_retention] in deploy/zeroclaw-cron.template.toml.
set -euo pipefail
TRIAGE="$HOME/.zeroclaw/workspace/gh-notif/triage"
[ -d "$TRIAGE" ] || exit 0
find "$TRIAGE" -mindepth 1 -maxdepth 1 -type d -mtime +14 -print -exec rm -rf {} +
echo "retention: pruned binders >14d under $TRIAGE"
