# Setup — fork & run it on your own GitHub

Two ways to run it; both are **draft-only** (read-only on GitHub).

## What you provide (your parameters / secrets)
- **Your GitHub account.** The skills read *your* notification inbox via the `gh`
  CLI — nothing is repo-specific, so there's no repo to configure. Just
  `gh auth login` (read scope is enough).
- **A model provider key.** Claude (Anthropic) recommended. In Claude Code it's
  already set; in ZeroClaw set it in `~/.zeroclaw/config.toml`.
- **(ZeroClaw digest only) a chat channel id** — e.g. your Discord DM channel id,
  where the daily digest is delivered.

## Option A — Claude Code (interactive)
1. Copy `.claude/skills/github-notification-orchestrator` and
   `.claude/skills/github-prior-art` into your project's `.claude/skills/` (or
   `~/.claude/skills/`).
2. `gh auth login`.
3. Say **"orchestrate my notifications"** (or `/github-notification-orchestrator`).
   You get a dated `triage/<date>/` binder of per-item drafts + an `INDEX.md`.

## Option B — ZeroClaw (scheduled, hands-off)
1. Install the skills to a stable path:
   `cp -R .claude/skills/* ~/.zeroclaw/skills/`
2. Create the dirs:
   `mkdir -p ~/.zeroclaw/workspace/gh-notif/{state,triage} ~/.zeroclaw/agents/gh_notif/workspace`
3. **Seed the state** so the first tick doesn't draft your whole backlog:
   ```bash
   SK=~/.zeroclaw/skills/github-notification-orchestrator
   ST=~/.zeroclaw/workspace/gh-notif/state
   B=~/.zeroclaw/workspace/gh-notif/triage/$(date +%F)
   bash $SK/scripts/notifications_delta.sh delta  "$ST" "$B"
   bash $SK/scripts/notifications_delta.sh commit "$ST" "$B"
   ```
4. Open `deploy/zeroclaw-cron.template.toml`, replace the placeholders
   (`<HOME>`, `<MODEL_PROVIDER>`, `<DISCORD_CHANNEL_ID>`), back up your config
   (`cp ~/.zeroclaw/config.toml ~/.zeroclaw/config.toml.bak`), and append it.
5. Restart so the scheduler picks up the jobs: `zeroclaw service restart`.
6. Verify before enabling: `zeroclaw agent -a gh_notif -m "reply: gh_notif online"`.
7. Flip `enabled = true` on `[cron.gh_notif_poll]` (and `[cron.gh_notif_digest]`)
   when ready. Start the poll at **every 30 min** to feel out cost, then tighten.

### Notes
- **First-run cap.** The poll prompt caps drafts per tick, and seeding (step 3)
  means only *new* notifications draft — so you never get a backlog burst. The
  loop is at-least-once + restart-safe: a daemon restart only re-*drafts*, never
  re-posts (it's draft-only).
- **Permissions.** The template uses a `yolo`-class risk profile so the agent's
  shell can run the bundled scripts + read-only `gh`. The prompt is draft-only
  and `gh` is read-only, so the blast radius is bounded — tighten
  `allowed_commands` to `["bash","gh","python3","jq","date"]` if you prefer a
  smaller surface (and re-test).
- **Cost.** Piece C (digest) is ~free (a deterministic index build + a short
  lede; it rolls up Piece A's drafts, never re-drafts). Piece A's cost scales
  with how many *new* notifications arrive per tick.
- **Do you need Piece C?** Piece A drafts silently into the binder; Piece C is
  what *delivers* a single daily briefing to your chat and rebuilds the
  whole-day INDEX. Keep it unless you'll always open the binder folder yourself.
