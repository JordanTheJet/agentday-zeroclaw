# Setup — fork & run it on your own GitHub

Two ways to run it; both are **draft-only** (read-only on GitHub).

## Prerequisites
- **Command-line tools the scripts call:** `gh` (GitHub CLI), `git`, `jq`, and
  `rsync` (`rsync` only for the optional drafts mirror); `awk`/`bash` are assumed.
  Debian/Ubuntu: `sudo apt-get install -y gh git jq rsync`.
- **(ZeroClaw path only) the `zeroclaw` binary, ≥ 0.8.2.** It is built from source
  (not on crates.io) — the cron template uses version-gated features (`delegate`,
  `delegation_policy`, `runtime_profile`, `skill_bundles`, `slash_commands`):
  ```bash
  # install Rust, then build + install zeroclaw
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && . "$HOME/.cargo/env"
  git clone https://github.com/zeroclaw-labs/zeroclaw.git && cd zeroclaw && cargo install --path .
  zeroclaw --version      # expect 0.8.2+
  zeroclaw quickstart     # creates ~/.zeroclaw/config.toml + a provider
  ```
  (Phase 3 PR-building additionally needs the `claude` CLI.)

## What you provide (your parameters / secrets)
- **Your GitHub account.** The skills read *your* notification inbox via the `gh`
  CLI — nothing is repo-specific, so there's no repo to configure. Authenticate
  **with the `notifications` scope** — the inbox fetch needs it, and a bare
  `gh auth login` web flow does **not** grant it:
  ```bash
  gh auth login --hostname github.com --git-protocol https --scopes 'notifications,repo,read:org'
  gh api notifications --jq 'length'    # preflight: must NOT 403
  ```
  (add `workflow` only if you'll use Phase 3 PR builds.)
- **A model provider key.** Claude (Anthropic) recommended. In Claude Code it's
  already set; in ZeroClaw set it in `~/.zeroclaw/config.toml` (via `zeroclaw quickstart`).
- **(ZeroClaw digest only) a chat channel.** The daily digest delivers to a chat
  channel via `[channels.discord.default]` (create a Discord app + bot, enable the
  **Message Content Intent**, set its `bot_token`). This is a prerequisite *only if
  you enable the digest cron* — if you skip it, leave `[cron.gh_notif_digest]`
  disabled and Piece A still drafts into the on-host binder (the default delivery).

## Option A — Claude Code (interactive)
1. Copy `.claude/skills/github-notification-orchestrator` and
   `.claude/skills/github-duplicate-check` into your project's `.claude/skills/` (or
   `~/.claude/skills/`).
2. `gh auth login`.
3. Say **"orchestrate my notifications"** (or `/github-notification-orchestrator`).
   You get a dated `triage/<date>/` binder of per-item drafts + an `INDEX.md`.

## Option B — ZeroClaw (scheduled, hands-off)
1. Install the skills to a stable path:
   `cp -R .claude/skills/* ~/.zeroclaw/skills/`
2. Create the dirs:
   `mkdir -p ~/.zeroclaw/workspace/gh-notif/{state,triage} ~/.zeroclaw/agents/gh_notif/workspace ~/.zeroclaw/bin`
3. **Seed the state** so the first tick doesn't draft your whole backlog. (This
   calls `gh api notifications` — if it errors, your token is missing the
   `notifications` scope; re-run the `gh auth login` above.)
   ```bash
   SK=~/.zeroclaw/skills/github-notification-orchestrator
   ST=~/.zeroclaw/workspace/gh-notif/state
   B=~/.zeroclaw/workspace/gh-notif/triage/$(date +%F)
   bash $SK/scripts/notifications_delta.sh delta  "$ST" "$B"
   bash $SK/scripts/notifications_delta.sh commit "$ST" "$B"
   ```
4. Open `deploy/zeroclaw-cron.template.toml`, replace the placeholders
   (`<HOME>`, `<MODEL_SONNET>`, `<MODEL_OPUS>`, `<DISCORD_CHANNEL_ID>`), back up
   your config (`cp ~/.zeroclaw/config.toml ~/.zeroclaw/config.toml.bak`), and
   append it. The template wires up the orchestrator (`gh_notif`) **plus six
   sub-agents** and two risk profiles, so it's a few more blocks than before.
   Model split: the orchestrator and four workers (`gh_notif_issue`,
   `gh_notif_mention`, `gh_notif_author`, `gh_notif_ci`) use `<MODEL_SONNET>`;
   `gh_notif_pr_reviewer` and `gh_notif_verifier` use `<MODEL_OPUS>`.
   The template also wires a daily **retention** cron (`gh_notif_retention`) that
   prunes binders older than 14 days — install its prune script so the job
   resolves:
   ```bash
   cp deploy/gh-notif-retention.sh ~/.zeroclaw/bin/ && chmod +x ~/.zeroclaw/bin/gh-notif-retention.sh
   ```
5. Restart so the scheduler picks up the jobs: `zeroclaw service restart`.
6. Verify before enabling: `zeroclaw agent -a gh_notif -m "reply: gh_notif online"`.
   On a real tick the orchestrator routes each new notification to one sub-agent
   via the `delegate` tool and waits for it to return (a draft file path) before
   handling the next.
7. Flip `enabled = true` on `[cron.gh_notif_poll]` (and `[cron.gh_notif_digest]`,
   and `[cron.gh_notif_retention]` once its script is installed) when ready. Start
   the poll at **every 30 min** to feel out cost, then tighten.

### Optional: clickable digest links (private drafts repo)
By default the digest footer points at the on-host binder path. To get **tappable
links to each draft from chat/mobile**, mirror the binder to a *private* GitHub repo:
1. Create a private repo: `gh repo create <you>/gh-notif-drafts --private --add-readme`
2. Tell the publisher where it lives:
   `echo "<you>/gh-notif-drafts" > ~/.zeroclaw/workspace/gh-notif/.drafts-remote`

That's it — the poll and digest crons already call `publish_drafts.sh`, which is a
no-op until `.drafts-remote` exists. Once set, every line of the daily digest is a
masked GitHub link to that draft's rendered summary, and `build_index.sh` emits
absolute GitHub URLs. **Keep this repo private** — the drafts contain unsent
replies and candid verifier verdicts about other people's PRs; never publish them.

### Optional: accept → post (the shipper)
Each draft carries a "Ready-to-post comment" block and `status: needs-reply`. To act:
1. Read the draft (in the private repo, from anywhere). Edit the block if needed,
   set its frontmatter to `status: accepted`, and commit.
2. The **shipper** posts that block to the thread as a **comment** via `gh` —
   deterministically (no LLM in the posting path), comments ONLY (never
   review/approve/merge/close/label) — then flips the draft to `status: posted`
   and records the comment URL.

Run it either way:
- **Manual:** `bash ~/.zeroclaw/skills/github-notification-orchestrator/scripts/ship_accepted.sh ~/.zeroclaw/workspace/gh-notif`
  — dry-run by default (prints exactly what it WOULD post); add `--post` to send,
  `--repo OWNER/REPO` / `--only SUBSTR` to scope a run.
- **Hands-off:** flip `enabled = true` on `[cron.gh_notif_ship]`; it sweeps
  accepted drafts every 15 min.

Safety: the drafting agents always write `status: needs-reply` and never
`accepted` — that flag is *your* go-ahead, so nothing posts until you accept it.
Posting is comments-only and idempotent (an accepted draft posts once, then
becomes `posted`). Start with the manual dry-run before enabling the cron.

### Notes
- **First-run cap.** The poll prompt caps drafts per tick, and seeding (step 3)
  means only *new* notifications draft — so you never get a backlog burst. The
  loop is at-least-once + restart-safe: a daemon restart only re-*drafts*, never
  re-posts (it's draft-only).
- **Permissions.** The template ships **two** risk profiles. The orchestrator
  (`gh_notif`) has `delegation_policy` mode `allow` plus a `delegates` roster
  naming the six sub-agents, and lists `delegate` in the poll's `allowed_tools`
  so it can hand work off. The sub-agents share `gh_notif_worker`, which is
  identical on every axis *except* `delegation_policy` is `forbidden` (they
  can't re-delegate or escalate — ZeroClaw enforces a no-escalation guard at
  delegate time). Both are full-shell so the agents can run the bundled scripts
  + read-only `gh`; the prompts are draft-only and `gh` is read-only, so the
  blast radius is bounded — tighten `allowed_commands` to
  `["bash","gh","python3","jq","date"]` on both profiles if you prefer a smaller
  surface (and re-test).
- **Cost.** Piece C (digest) is ~free (a deterministic index build + a short
  lede; it rolls up Piece A's drafts, never re-drafts). Piece A's cost scales
  with how many *new* notifications get drafted per tick: delegation is
  **synchronous/serial** (the orchestrator delegates one sub-agent at a time and
  waits for each), bounded by the per-tick cap of **5 newest** notifications. So
  a tick is at most one orchestrator routing pass + up to 5 worker drafts + a
  verifier pass on any PR-review draft — no runaway fan-out.
- **Do you need Piece C?** Piece A drafts silently into the binder; Piece C is
  what *delivers* a single daily briefing to your chat and rebuilds the
  whole-day INDEX. Keep it unless you'll always open the binder folder yourself.

## Optional: drive it from Discord (slash commands) + Phase 3 (code → PR)

**Discord chat (`/gh-draft`):**
1. Install the `gh-draft` skill into a bundle attached to the chat agent:
   ```bash
   zeroclaw skills bundle add ghnotif
   cp -R .claude/skills/gh-draft ~/.zeroclaw/shared/skills/ghnotif/
   ```
   (the template's `[agents.gh_notif_chat]` already sets `skill_bundles = ["ghnotif"]`
   + `channels = ["discord.default"]`).
2. Set `slash_commands = true` under `[channels.discord.default]`.
3. Authorize yourself — slash commands **and** buttons are gated to an allowlist:
   ```toml
   [peer_groups.gh_notif]
   channel = "discord.default"
   external_peers = ["<YOUR_DISCORD_USER_ID>"]
   ```
   (if you get *"you're not authorized to use this command here"*, your id is in the
   daemon trace's "unauthorized interaction" warning).
4. Restart. In Discord: `/gh-draft show #1234`, `/gh-draft edit #1234 <change>`,
   `/gh-draft ask #1234 <q>`, `/gh-draft accept #1234`, `/gh-draft implement #1234`.
   `show` includes Edit / Accept / Open-PR buttons. Global commands take up to ~1h to
   appear in the client; `slash_command_scope = "guild"` + `guild_ids` is instant.

**Phase 3 (accept code → draft PR):** `implement` (or `scripts/ship_pr.sh <ws>
--only <file>`) builds a **draft PR from your fork** via a local **Claude Code**
harness (install the `claude` CLI) + the `github-pr` skill (a separate skill you
install for Phase 3 — it enforces the PR template + no-attribution). Dry-run by default; `--open` (requires `--only`/`--repo`)
actually clones, builds, and opens a **draft** PR — review it before marking Ready.

## Sharing your ZeroClaw config safely (no secrets)

To show a working ZeroClaw setup without leaking anything: **never commit
`~/.zeroclaw/config.toml`** — it holds `paired_tokens`, provider API keys, and
channel `bot_token`s.

- **The shareable example is [`deploy/zeroclaw-cron.template.toml`](deploy/zeroclaw-cron.template.toml)** —
  it is exactly the `gh_notif` agent + risk profile + cron jobs from a real
  deployment, with every secret/host value replaced by a `<PLACEHOLDER>`.
- It's self-contained: the only blocks you add to a fresh ZeroClaw config are
  `[risk_profiles.gh_notif]` + `[risk_profiles.gh_notif_worker]`,
  `[agents.gh_notif*]` (the orchestrator + six sub-agents), and `[cron.gh_notif*]`
  — no providers/channels/tokens are part of the example.
- Before committing any config excerpt, verify it's clean:
  `grep -niE 'enc2:|sk-|gho_|ghp_|api_key|bot_token|paired_tokens' <file>` must
  return nothing.

## Running 24/7 on a remote host

To move a live deployment to an always-on box (and supervise it without launchd):

1. On the source host: `bash deploy/migrate.sh` packages the must-transfer state
   into one tarball (config + `.secret_key` + `seen.tsv` + drafts clone + skills +
   a checkpoint-clean memory DB) and **excludes** the ~143 MB scratch clone and all
   per-host runtime. It is read-only on `~/.zeroclaw`. It also emits a
   `SECRETS-TO-SET.txt` checklist computed from your actual host.
2. Follow [`deploy/REMOTE_SETUP.md`](deploy/REMOTE_SETUP.md) — it covers the
   single-daemon cutover, secret portability (the `enc2:` key file is host-portable,
   the gh token is not), the `/Users → $HOME` path rewrite (+ the Linux `/home`
   `forbidden_paths` trap), timezone (the digest cron fires in local time), and
   bringing the daemon up under the [`deploy/zeroclaw.service`](deploy/zeroclaw.service)
   systemd `--user` unit (`loginctl enable-linger` for boot/logout survival).

The drafts-only invariant is preserved across the move: `gh_notif_ship` stays
`enabled = false`, so nothing posts upstream during or after migration.
