#!/usr/bin/env bash
#
# migrate.sh — package a ZeroClaw "gh_notif" GitHub-notification triage
#              deployment for migration to a 24/7 host (Linux).
#
# RUNS ON: the SOURCE host (the machine that runs the daemon today). macOS bash
#          3.2 compatible. Pure bash — NO python. Uses tar/cp/find/grep/wc/stat
#          and (optionally) sqlite3 + gh for a checkpoint-clean DB + auth report.
#
# It is READ-ONLY on ~/.zeroclaw: it never edits config, never stops the daemon,
# never runs a state-changing `zeroclaw` subcommand, never pushes a git remote.
# It only READS from the source and WRITES one tarball + manifests to --out.
#
# WHAT IT PACKAGES (the must-transfer set; see EXCLUDED.txt for what it drops):
#   config.toml, .secret_key (Path A), auth-profiles.json, the gh-notif workspace
#   state (seen.tsv dedup ledger, .drafts-remote pointer, the drafts-repo clone),
#   the three installed skills + the shared "ghnotif" bundle, the bin/ cron
#   helpers, and a checkpoint-clean copy of the memory DB. It EXCLUDES the ~143M
#   scratch code-repos clone, all per-host runtime (sockets/pids/logs/sessions),
#   and config backups.
#
# SECRETS (read the banner it prints):
#   Provider API keys live in config.toml as `enc2:` ciphertext, decryptable ONLY
#   with ~/.zeroclaw/.secret_key (ChaCha20-Poly1305; the file IS the key, no
#   keychain/machine binding). The Discord bot_token is PLAINTEXT in config.toml.
#   * Path A (DEFAULT, recommended): include .secret_key so the encrypted keys
#     keep working on the target. The tarball is then secret-bearing — move it
#     over an encrypted channel and wipe it after.
#   * Path B (--no-secret-key): omit the key. You MUST then strip EVERY stale
#     enc2: value from config.toml + auth-profiles.json on the target and
#     re-enter secrets (a fresh key cannot decrypt the old ciphertext, and the
#     daemon fails decryption of ALL enc2 fields at startup, not just gh_notif's).
#     SECRETS-TO-SET.txt lists the exact enc2 line numbers to strip.
#
# USAGE:
#   bash migrate.sh                  # Path A (include .secret_key) — recommended
#   bash migrate.sh --no-secret-key  # Path B (omit key; re-encrypt on target)
#   bash migrate.sh --no-memory      # skip the memory DB (continuity-only)
#   bash migrate.sh --out /some/dir  # output dir (default: ~/Desktop)
#
set -u

# ---------------------------------------------------------------------------
# 0. Args
# ---------------------------------------------------------------------------
ZC="$HOME/.zeroclaw"
GHN="$ZC/workspace/gh-notif"
OUT_DIR="$HOME/Desktop"
INCLUDE_SECRET_KEY=1
INCLUDE_MEMORY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-secret-key) INCLUDE_SECRET_KEY=0 ;;
    --no-memory)     INCLUDE_MEMORY=0 ;;
    --out)           shift; OUT_DIR="${1:-$OUT_DIR}" ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               echo "WARN: ignoring unknown arg: $1" >&2 ;;
  esac
  shift
done

STAMP="$(date +%Y%m%dT%H%M%S)"
STAGE="$OUT_DIR/zeroclaw-ghnotif-migrate-$STAMP"
PAYLOAD="$STAGE/zeroclaw-ghnotif"          # mirrors the ~/.zeroclaw layout
TARBALL="$OUT_DIR/zeroclaw-ghnotif-$STAMP.tar.gz"
MANIFEST="$PAYLOAD/MANIFEST.txt"

# ---------------------------------------------------------------------------
# 1. Preflight (read-only assertions)
# ---------------------------------------------------------------------------
[ -d "$ZC" ]              || { echo "FATAL: $ZC missing — run on the source host." >&2; exit 1; }
[ -f "$ZC/config.toml" ] || { echo "FATAL: $ZC/config.toml missing — nothing to migrate." >&2; exit 1; }

echo "============================================================"
echo " ZeroClaw gh_notif migration packager (read-only on source)"
echo "============================================================"
echo " source      : $ZC"
echo " output dir  : $OUT_DIR"
echo " tarball     : $TARBALL"
if [ "$INCLUDE_SECRET_KEY" -eq 1 ]; then
  echo " secret key  : INCLUDED (Path A — encrypted keys travel; PROTECT this tarball)"
else
  echo " secret key  : OMITTED  (Path B — strip stale enc2 + re-enter secrets on target)"
fi
[ "$INCLUDE_MEMORY" -eq 1 ] && echo " memory db   : INCLUDED (checkpoint-clean if sqlite3 present)" \
                            || echo " memory db   : OMITTED  (--no-memory; continuity-only)"
echo "------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 2. Idempotent staging (wipe + recreate our OWN output only)
# ---------------------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$PAYLOAD" || { echo "FATAL: cannot create $PAYLOAD" >&2; exit 1; }

# init manifest (printf so tabs are real tabs, not literal \t)
{
  printf '# ZeroClaw gh_notif migration manifest\n'
  printf '# generated : %s\n' "$(date)"
  printf '# src host  : %s (%s)\n' "$(hostname 2>/dev/null)" "$(uname -srm)"
  printf '# src HOME  : %s\n' "$HOME"
  printf '# zeroclaw  : %s\n' "$(zeroclaw --version 2>/dev/null || echo '?')"
  printf '# zc source : %s\n' "$(grep -o 'zeroclawlabs [0-9.]* (path[^)]*)' "$HOME/.cargo/.crates.toml" 2>/dev/null | head -1 || echo '?')"
  printf '# TZ        : %s (%s)\n' "$(readlink /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')" "$(date +%Z)"
  printf '# git id    : %s <%s>\n' "$(git config --global user.name 2>/dev/null)" "$(git config --global user.email 2>/dev/null)"
  printf '# drafts    : %s\n' "$(cat "$GHN/.drafts-remote" 2>/dev/null)"
  printf '# secret_key included: %s | memory included: %s\n' "$INCLUDE_SECRET_KEY" "$INCLUDE_MEMORY"
  printf '# format: <kind>\t<relpath>\t<info>\t<source>\n'
} >"$MANIFEST"

# copy_file <abs-src> <rel-dest>
copy_file() {
  src="$1"; rel="$2"
  if [ ! -e "$src" ]; then
    echo "  SKIP (absent): $src" >&2
    printf 'skip-absent\t%s\t-\t%s\n' "$rel" "$src" >>"$MANIFEST"; return 0
  fi
  dest="$PAYLOAD/$rel"; mkdir -p "$(dirname "$dest")"
  cp -p "$src" "$dest" || { echo "  ERROR copying $src" >&2; return 1; }
  sz="$(wc -c <"$src" | tr -d ' ')"
  echo "  + $rel  (${sz}B)"
  printf 'file\t%s\t%sB\t%s\n' "$rel" "$sz" "$src" >>"$MANIFEST"
}

# copy_dir <abs-src-dir> <rel-dest> [prune-glob ...]
copy_dir() {
  src="$1"; rel="$2"; shift 2
  if [ ! -d "$src" ]; then
    echo "  SKIP (absent dir): $src" >&2
    printf 'skip-absent-dir\t%s\t-\t%s\n' "$rel" "$src" >>"$MANIFEST"; return 0
  fi
  dest="$PAYLOAD/$rel"; mkdir -p "$(dirname "$dest")"
  cp -Rp "$src" "$dest" || { echo "  ERROR copying dir $src" >&2; return 1; }
  while [ $# -gt 0 ]; do
    find "$dest" -name "$1" -prune -exec rm -rf {} + 2>/dev/null
    shift
  done
  cnt="$(find "$dest" -type f | wc -l | tr -d ' ')"
  echo "  + $rel/  (${cnt} files)"
  printf 'dir\t%s\t%s files\t%s\n' "$rel" "$cnt" "$src" >>"$MANIFEST"
}

# copy_sqlite <abs-src.db> <rel-dest.db> — checkpoint-clean via sqlite3 .backup
# (avoids importing a torn live WAL); falls back to raw db+wal+shm if no sqlite3.
copy_sqlite() {
  src="$1"; rel="$2"
  if [ ! -f "$src" ]; then
    echo "  SKIP (absent): $src" >&2
    printf 'skip-absent\t%s\t-\t%s\n' "$rel" "$src" >>"$MANIFEST"; return 0
  fi
  dest="$PAYLOAD/$rel"; mkdir -p "$(dirname "$dest")"
  if command -v sqlite3 >/dev/null 2>&1 && sqlite3 "$src" ".backup '$dest'" 2>/dev/null; then
    sz="$(wc -c <"$dest" | tr -d ' ')"
    echo "  + $rel  (checkpoint-clean, ${sz}B)"
    printf 'sqlite-backup\t%s\t%sB\t%s\n' "$rel" "$sz" "$src" >>"$MANIFEST"; return 0
  fi
  echo "  WARN: sqlite3 .backup unavailable for $src — raw copy WITH -wal/-shm" >&2
  cp -p "$src" "$dest" 2>/dev/null
  [ -f "$src-wal" ] && cp -p "$src-wal" "$dest-wal" 2>/dev/null
  [ -f "$src-shm" ] && cp -p "$src-shm" "$dest-shm" 2>/dev/null
  printf 'raw-sqlite\t%s\t(not checkpoint-clean)\t%s\n' "$rel" "$src" >>"$MANIFEST"
}

# ---------------------------------------------------------------------------
# 3. MUST-TRANSFER set
# ---------------------------------------------------------------------------
echo; echo ">> Core config + auth profiles"
copy_file "$ZC/config.toml"        "config.toml"
copy_file "$ZC/auth-profiles.json" "auth-profiles.json"

if [ "$INCLUDE_SECRET_KEY" -eq 1 ]; then
  echo; echo ">> Master secret key (.secret_key) — Path A"
  copy_file "$ZC/.secret_key" ".secret_key"
else
  echo; echo ">> .secret_key OMITTED (Path B) — re-encrypt on target"
  printf 'skip-by-flag\t.secret_key\t(Path B)\t%s\n' "$ZC/.secret_key" >>"$MANIFEST"
fi

echo; echo ">> gh-notif workspace state (dedup ledger + drafts pointer + drafts clone)"
copy_file "$GHN/state/seen.tsv" "workspace/gh-notif/state/seen.tsv"
copy_file "$GHN/.drafts-remote" "workspace/gh-notif/.drafts-remote"
copy_dir  "$GHN/drafts-repo"    "workspace/gh-notif/drafts-repo"   # source of truth for accept/posted state (incl .git)

echo; echo ">> Installed skills referenced by config (by absolute path)"
copy_dir  "$ZC/skills/github-notification-orchestrator" "skills/github-notification-orchestrator" "examples"
copy_dir  "$ZC/skills/github-duplicate-check"           "skills/github-duplicate-check"
copy_dir  "$ZC/skills/gh-draft"                         "skills/gh-draft"

echo; echo ">> Shared skill bundle 'ghnotif' (the Discord chat agent's payload)"
copy_dir  "$ZC/shared/skills/ghnotif" "shared/skills/ghnotif"

echo; echo ">> bin/ helpers (cron retention target + gh-drafts helper)"
copy_file "$ZC/bin/gh-notif-retention.sh" "bin/gh-notif-retention.sh"
copy_file "$ZC/bin/gh-drafts"             "bin/gh-drafts"

if [ "$INCLUDE_MEMORY" -eq 1 ]; then
  echo; echo ">> Memory + scheduler state (checkpoint-clean)"
  copy_sqlite "$ZC/data/memory/brain.db"    "data/memory/brain.db"
  copy_sqlite "$ZC/data/cron/jobs.db"       "data/cron/jobs.db"
fi

echo; echo ">> Path-rewrite reference (the <HOME>-placeholder template)"
copy_file "$(cd "$(dirname "$0")" && pwd)/zeroclaw-cron.template.toml" "reference/zeroclaw-cron.template.toml"

# ---------------------------------------------------------------------------
# 4. EXCLUDED.txt — what we deliberately left out (and why)
# ---------------------------------------------------------------------------
{
  echo "# Deliberately EXCLUDED (regenerable or non-portable)."
  echo
  echo "## Regenerable on target — do NOT transfer:"
  echo "workspace/gh-notif/code-repos/zeroclaw    ~143M scratch git clone (git clone on target)"
  echo "workspace/gh-notif/code-repos/zeroclaw.wt empty worktree parent (recreated on demand)"
  echo "workspace/gh-notif/triage/<DATE>          dated binders (regenerated each poll; seen.tsv prevents re-draft)"
  echo "skills/.../examples                       frozen docs runs (not runtime)"
  echo "data/sessions, data/state, data/devices.db  per-host runtime telemetry"
  echo "config.toml.bak-*/.backup/.scratch-*      historical config snapshots"
  echo
  echo "## Per-host runtime — NEVER copy (recreated when the daemon starts):"
  echo "data/daemon.sock, a2a-gateway-*.pid/.log, daemon.{log,out,err}, state/daemon_state.json"
  echo
  echo "## Non-portable auth — re-establish on target (NOT in this tarball):"
  echo "~/.config/gh         gh token is in the OS keyring, not hosts.yml -> run 'gh auth login' fresh."
  echo "~/.gitconfig         its credential helper points at the source host's gh path"
  echo "                     (e.g. /opt/homebrew/bin/gh) -> do NOT copy; run 'gh auth setup-git' instead."
  [ "$INCLUDE_SECRET_KEY" -eq 0 ] && echo "~/.zeroclaw/.secret_key  OMITTED (--no-secret-key; Path B re-encrypt)."
} >"$PAYLOAD/EXCLUDED.txt"
echo; echo ">> Wrote EXCLUDED.txt"

# ---------------------------------------------------------------------------
# 5. SECRETS-TO-SET.txt (concrete to THIS host; never prints raw key material)
# ---------------------------------------------------------------------------
SECCK="$PAYLOAD/SECRETS-TO-SET.txt"
GH_SCOPES="$(gh auth status 2>/dev/null | grep -i 'Token scopes' | head -1 | sed "s/.*scopes: //" || true)"
DRAFT_SLUG="$(cat "$GHN/.drafts-remote" 2>/dev/null)"
ENC2_LINES="$(grep -n 'enc2:' "$ZC/config.toml" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
{
  echo "# SECRETS-TO-SET on the target. DRAFT-ONLY system: keep gh_notif_ship enabled=false."
  echo "# (No raw keys are written here — only what to set and where.)"
  echo
  echo "## ALWAYS re-establish on the target (these do NOT travel in the tarball):"
  echo "[ ] gh CLI auth — ADD the 'notifications' scope (the poll path needs it):"
  echo "      gh auth login --hostname github.com --git-protocol https \\"
  echo "        --scopes 'notifications,repo,workflow,read:org'"
  echo "      gh auth setup-git        # wire gh in as the HTTPS git credential helper"
  echo "    source token scopes were: ${GH_SCOPES:-<run: gh auth status>}"
  echo "    (if 'notifications' is NOT listed above, the first poll tick 403s until you add it)"
  echo "[ ] git identity:"
  echo "      git config --global user.name  '$(git config --global user.name 2>/dev/null)'"
  echo "      git config --global user.email '$(git config --global user.email 2>/dev/null)'"
  echo "[ ] drafts repo '${DRAFT_SLUG:-<owner/repo>}' must EXIST + be PRIVATE on the target account."
  echo "      (the .drafts-remote pointer + drafts-repo clone ARE in this tarball)"
  echo "[ ] claude CLI auth — only for ship_pr/review_evidence (Phase 3). Set ANTHROPIC_API_KEY"
  echo "    in the daemon env, or run 'claude' once over SSH."
  echo
  if [ "$INCLUDE_SECRET_KEY" -eq 1 ]; then
    echo "## Path A (you INCLUDED .secret_key): provider keys + Discord token decrypt unchanged."
    echo "   NOTHING to re-enter. But this tarball carries the master key + the PLAINTEXT Discord"
    echo "   bot_token — move it over scp/age only, and after unpack:"
    echo "[ ] chmod 600 on target: ~/.zeroclaw/.secret_key  ~/.zeroclaw/config.toml  ~/.zeroclaw/auth-profiles.json"
    echo "[ ] securely delete the tarball + any transient copies."
  else
    echo "## Path B (you OMITTED .secret_key): a FRESH key on the target cannot decrypt the old"
    echo "   ciphertext. You MUST strip EVERY stale enc2: value, then re-enter secrets:"
    echo "[ ] In config.toml, blank/remove the enc2: values on these lines: ${ENC2_LINES:-<grep -n enc2: config.toml>}"
    echo "[ ] Also strip enc2: values from auth-profiles.json."
    echo "[ ] Re-enter (zeroclaw quickstart / config setter, re-encrypts under the new key):"
    echo "      - Anthropic API key (anthropic.default=sonnet, anthropic.opus=opus)  <- gh_notif needs these"
    echo "      - Discord bot_token ([channels.discord.default].bot_token)           <- gh_notif needs this"
    echo "      - any other provider only if you keep its (non-gh_notif) agent"
    echo "   TIP: it is simpler to keep ONLY the gh_notif* agents + their 2 risk profiles + the 2"
    echo "        anthropic providers + the discord channel, and delete the rest."
  fi
  echo
  echo "## Discord Developer Portal (either path):"
  echo "[ ] Enable MESSAGE CONTENT INTENT (required for /gh-draft inbound text)."
  echo "[ ] Bot invite includes the applications.commands scope (for slash commands)."
  echo "[ ] [peer_groups.gh_notif] external_peers holds your Discord user id."
} >"$SECCK"
echo ">> Wrote SECRETS-TO-SET.txt"

# ---------------------------------------------------------------------------
# 6. Tarball
# ---------------------------------------------------------------------------
echo; echo ">> Building tarball..."
tar -czf "$TARBALL" -C "$STAGE" "zeroclaw-ghnotif" || { echo "FATAL: tar failed" >&2; exit 1; }
TSIZE="$(wc -c <"$TARBALL" | tr -d ' ')"

echo "------------------------------------------------------------"
echo " DONE."
echo " tarball : $TARBALL  (${TSIZE}B)"
echo " staging : $STAGE  (inspect MANIFEST.txt / EXCLUDED.txt / SECRETS-TO-SET.txt)"
if [ "$INCLUDE_SECRET_KEY" -eq 1 ]; then
  echo
  echo " *** This tarball contains .secret_key + a PLAINTEXT Discord bot_token.   ***"
  echo " *** Transfer over an ENCRYPTED channel (scp/age) only, then wipe it.     ***"
fi
echo " Next: read REMOTE_SETUP.md and follow the go-live checklist."
echo "------------------------------------------------------------"
exit 0
