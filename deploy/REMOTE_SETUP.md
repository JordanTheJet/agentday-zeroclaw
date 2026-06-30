# REMOTE_SETUP.md — Move the ZeroClaw `gh_notif` triage system to a 24/7 Linux host

Stands up the **DRAFT-ONLY** GitHub-notification triage orchestrator on a Linux box
from the tarball that [`migrate.sh`](./migrate.sh) produces on the source host.
Supervised by **systemd `--user`** ([`zeroclaw.service`](./zeroclaw.service)) — **not launchd**.

**Invariants — do not break these during the move:**
- The system **never posts upstream**. Keep `cron.gh_notif_ship` `enabled = false`.
- The drafts repo stays **private**.
- Re-enter secrets per the tarball's `SECRETS-TO-SET.txt`; never commit raw keys.

`<HOME>` = the Linux daemon user's home (e.g. `/home/you`); `<USER>` = that user.
The source paths were all under the source `$HOME` (see `MANIFEST.txt` → `# src HOME`).

---

## Order of operations (don't reorder — the first two steps are gates)

```
1. STOP the old source daemon   ← single-daemon gate (do this FIRST)
2. Choose Path A or Path B      ← secrets gate
3. Install prereqs  →  4. Set TZ  →  5. Transfer+unpack  →  6. Rewrite paths
7. Re-establish auth  →  8. Start under systemd  →  9. Verify  →  (10. Rollback)
```

---

## 1. STOP the old daemon on the source host (single-daemon rule — FIRST)

Only **one** daemon may own the Discord bot token + the `gh_notif` crons at a time.
Two live daemons ⇒ **double 9am digests**, poll ticks racing on `seen.tsv`, and
Discord gateway session thrash (the bot reconnecting between two owners).

On the **source host**, stop the service **and** any manually-launched instance
(`zeroclaw service stop` alone does **not** kill a hand-started `--ephemeral` process):

```bash
zeroclaw service stop 2>/dev/null || true
# also kill any manual/ephemeral daemon the service manager doesn't own:
pkill -f 'zeroclaw daemon' 2>/dev/null; sleep 3; pkill -9 -f 'zeroclaw daemon' 2>/dev/null
pgrep -fl 'zeroclaw daemon'        # MUST print nothing before you continue
```

> Note: a `zerocode`/TUI session spawns its own `zeroclaw daemon --ephemeral` on the
> same config — close the TUI too, or it re-grabs the bot.

After it's quiesced, (re-)run `migrate.sh` on the source host so the memory DB is
captured checkpoint-clean while nothing is writing, then transfer that tarball.

---

## 2. Choose your secrets path

Secrets are `enc2:` ciphertext in `config.toml`, decryptable **only** with
`~/.zeroclaw/.secret_key` (ChaCha20-Poly1305 — the file *is* the key; no keychain,
no machine binding). The Discord `bot_token` is **plaintext** in `config.toml`.

- **Path A (default, recommended):** the tarball includes `.secret_key`, so every
  provider key + the Discord token decrypt unchanged — **nothing to re-enter**.
  Treat the tarball as a secret (it carries the master key + the plaintext token).
- **Path B (`migrate.sh --no-secret-key`):** the target generates a *fresh* key.
  A fresh key **cannot** decrypt the old ciphertext, and the daemon decrypts **every**
  `enc2:` field at startup (not just gh_notif's). So you must **strip every stale
  `enc2:` value** from `config.toml` *and* `auth-profiles.json` and re-enter secrets
  (the line numbers are listed in `SECRETS-TO-SET.txt`). Path A is far simpler.

`SECRETS-TO-SET.txt` (inside the tarball) records which path you took and the exact steps.

---

## 3. Install prereqs (Debian/Ubuntu, as `<USER>`)

```bash
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libssl-dev curl git gpg tzdata sqlite3

# Rust — the zeroclaw binary is built from source (it is NOT on crates.io).
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. "$HOME/.cargo/env"

# zeroclaw 0.8.2 — build from the same source the host used: a local checkout,
# installed with `cargo install --path .`. (MANIFEST.txt '# zc source' shows the
# exact path+version on the source host.)
git clone https://github.com/zeroclaw-labs/zeroclaw.git "$HOME/zeroclaw"   # or your fork
cd "$HOME/zeroclaw" && git checkout v0.8.2 2>/dev/null || true
cargo install --path .          # installs `zeroclaw` (+ zeroclaw-acp-bridge) to ~/.cargo/bin
zeroclaw --version              # expect: zeroclaw 0.8.2  (match the source host)

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt-get update && sudo apt-get install -y gh

# OPTIONAL (Phase 3 only): claude CLI for ship_pr / review_evidence
curl -fsSL https://claude.ai/install.sh | bash          # -> ~/.local/bin/claude

# OPTIONAL (sandboxed PR builds only): rootless podman
sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER" && podman system migrate
```

Record where the shell-outs live — you need these dirs in the systemd `PATH`:

```bash
command -v zeroclaw gh git claude podman
```

---

## 4. Set the timezone (the digest cron is LOCAL time)

ZeroClaw cron `expr` evaluates against the box's local time. A fresh Linux box is
usually UTC → the `0 9 * * *` digest would fire ~05:00 local and `0 4 * * *`
retention at midnight. Match the source host's zone (`MANIFEST.txt` → `# TZ`):

```bash
sudo timedatectl set-timezone America/New_York   # use your source-host zone
date +'%Z %z'                                     # expect EDT -0400 / EST -0500
```

`zeroclaw.service` also pins `Environment=TZ=...` as belt-and-suspenders.

---

## 5. Transfer + unpack (encrypted channel; into an EMPTY ~/.zeroclaw)

```bash
# from the source host (tarball defaults to ~/Desktop):
scp ~/Desktop/zeroclaw-ghnotif-*.tar.gz <USER>@<remote>:~/
```

On the target, unpack into a **clean** `~/.zeroclaw` (do this **before** any
`zeroclaw quickstart`, or a generated key/config will collide with the tarball):

```bash
[ -e "$HOME/.zeroclaw" ] && mv "$HOME/.zeroclaw" "$HOME/.zeroclaw.pre-$(date +%s)"  # stash any prior attempt
mkdir -p "$HOME/.zeroclaw"
tar -xzf ~/zeroclaw-ghnotif-*.tar.gz -C /tmp
cp -a /tmp/zeroclaw-ghnotif/. "$HOME/.zeroclaw/"
cat "$HOME/.zeroclaw/MANIFEST.txt" "$HOME/.zeroclaw/EXCLUDED.txt" "$HOME/.zeroclaw/SECRETS-TO-SET.txt"

# Lock down secret-bearing files + restore exec bits the tar/extract may have dropped:
chmod 600 "$HOME/.zeroclaw/config.toml" "$HOME/.zeroclaw/auth-profiles.json"
[ -f "$HOME/.zeroclaw/.secret_key" ] && chmod 600 "$HOME/.zeroclaw/.secret_key"
chmod 600 "$HOME/.zeroclaw/workspace/gh-notif/state/seen.tsv" 2>/dev/null || true
chmod +x "$HOME/.zeroclaw/bin/"* "$HOME/.zeroclaw/skills/"*/scripts/*.sh 2>/dev/null || true
```

---

## 6. Rewrite the source-host paths to `<HOME>`

Every absolute path in `config.toml` (and 2 lines of `skills/gh-draft/SKILL.md`)
points at the **source** `$HOME`. Rewrite **every occurrence** — don't trust a
hand-counted site list, trust the grep-returns-nothing check. Back up first.

```bash
SRC_HOME="$(grep -m1 '# src HOME' "$HOME/.zeroclaw/MANIFEST.txt" | sed 's/.*: //')"
echo "rewriting $SRC_HOME -> $HOME"
cp -p "$HOME/.zeroclaw/config.toml" "$HOME/.zeroclaw/config.toml.premigrate"

for f in "$HOME/.zeroclaw/config.toml" "$HOME/.zeroclaw/skills/gh-draft/SKILL.md"; do
  sed -i "s#${SRC_HOME}#${HOME}#g" "$f"
done

# Verify NOTHING references the old home (this is the source of truth, not a count):
grep -rn "$SRC_HOME" "$HOME/.zeroclaw/config.toml" "$HOME/.zeroclaw/skills/gh-draft/SKILL.md" \
  && echo "STILL HARDCODED — fix before starting" || echo "paths clean"
```

**Linux `/home` trap (only if you migrated the FULL config with all agents):**
some non-`gh_notif` risk profiles list a **literal** `/home` in `forbidden_paths`
(harmless on macOS where users live under `/Users`, but on Linux `/home` is the
*parent* of `$HOME`) — that deadlocks those agents' sandbox. The `/Users → $HOME`
sed does **not** touch it. The `gh_notif*` agents are unaffected. Simplest fix:
keep only the `gh_notif*` agents + their 2 risk profiles + the 2 anthropic
providers + the discord channel, and delete the rest. Otherwise, remove the
literal `/home` entry from any `forbidden_paths`:

```bash
grep -n "'/home'" "$HOME/.zeroclaw/config.toml"   # find offending forbidden_paths, edit them out
```

Confirm the ship cron stayed disabled (draft-only invariant):

```bash
awk '/\[cron.gh_notif_ship\]/{f=1} f&&/enabled/{print; exit}' "$HOME/.zeroclaw/config.toml"
# expect: enabled = false
```

---

## 7. Re-establish auth (follow `SECRETS-TO-SET.txt`)

```bash
# gh: ADD the 'notifications' scope (the source token lacked it) + repo + workflow.
gh auth login --hostname github.com --git-protocol https \
  --scopes "notifications,repo,workflow,read:org"
gh auth setup-git                       # wire gh in as the HTTPS credential helper
gh auth status                          # confirm 'notifications' + 'repo' present
gh api notifications --jq 'length'      # MUST NOT 403

# git identity (ship_pr commits use the ambient identity)
git config --global user.name  '<your name>'
git config --global user.email '<your email>'
```

> Do **NOT** copy the source `~/.gitconfig` — its credential helper points at the
> source host's `gh` path (e.g. `/opt/homebrew/bin/gh`), which doesn't exist on
> Linux. `gh auth setup-git` rewrites it correctly.

**Path B only:** strip every stale `enc2:` value (lines listed in `SECRETS-TO-SET.txt`)
from `config.toml` + `auth-profiles.json`, then re-enter the Anthropic keys
(`anthropic.default`=sonnet, `anthropic.opus`=opus) + the Discord `bot_token` via
`zeroclaw quickstart` / the config setter so they re-encrypt under the new key.

**Drafts repo** (it shipped as a clone; confirm it resolves AND that a write succeeds —
`publish_drafts.sh` swallows push errors with `|| true`, so a silent auth failure
would mirror drafts locally but never to GitHub and the digest links would 404):

```bash
DR="$HOME/.zeroclaw/workspace/gh-notif/drafts-repo"
git -C "$DR" remote -v                                   # -> the private drafts slug
git ls-remote "$(git -C "$DR" remote get-url origin)" >/dev/null && echo "read OK"
# positive WRITE check (empty commit; harmless, lands on origin):
git -C "$DR" commit --allow-empty -m "migration: verify push" -q \
  && git -C "$DR" push -q origin HEAD && echo "WRITE OK — credential helper works"
```

**Discord Developer Portal:** enable **Message Content Intent**, ensure the invite
has `applications.commands`, and confirm `[peer_groups.gh_notif] external_peers`
holds your Discord user id.

---

## 8. Start under systemd `--user` (not launchd)

```bash
mkdir -p "$HOME/.config/systemd/user"
# Save deploy/zeroclaw.service as ~/.config/systemd/user/zeroclaw.service, then
# edit it: replace <HOME>/<USER>, set Environment=PATH from step 3's `command -v`,
# set Environment=TZ to your zone.

loginctl enable-linger "$USER"              # start at boot + survive logout (REQUIRED)
loginctl show-user "$USER" -p Linger        # expect: Linger=yes
ls -d /run/user/$(id -u)                    # XDG_RUNTIME_DIR must exist (linger creates it)

systemctl --user daemon-reload
systemctl --user enable --now zeroclaw.service
systemctl --user status zeroclaw.service
```

> Lower-effort alternative: `zeroclaw service install --service-init systemd`.
> No-systemd fallback: see the tmux/nohup + `@reboot` cron runbook in
> [`zeroclaw-cron.template.toml`](./zeroclaw-cron.template.toml) header / the deploy notes.

### 8a. WSL (Windows host) specifics — required for true 24/7

WSL is a normal Linux userland, so everything above applies, but the host is
Windows and that changes *liveness*:

- **Enable systemd in WSL2** (off by default on older installs) or the `--user`
  unit + `loginctl` won't work. In the distro:
  ```bash
  printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
  ```
  Then from **Windows** (PowerShell): `wsl --shutdown`, reopen the distro, and
  `systemctl is-system-running` should respond. If you can't enable systemd, use
  the tmux/nohup fallback instead.
- **The distro must stay running.** WSL stops when its last process exits or
  Windows sleeps — which kills the daemon and makes the 9am cron miss. Two fixes,
  do both:
  1. `loginctl enable-linger "$USER"` keeps the user-manager (and the daemon) up
     while the distro lives — but the distro must be *launched* at boot. Add a
     **Windows Task Scheduler** task "At log on / At startup" running:
     `wsl.exe -d <Distro> -u <user> -- systemctl --user start zeroclaw.service`
     (or just `wsl.exe -d <Distro> -- true` to warm the distro so linger takes over).
  2. **Stop Windows from sleeping** (Settings → Power → Screen & sleep → Never, or
     `powercfg /change standby-timeout-ac 0`). A sleeping host pauses WSL and the
     cron clock, so the digest fires late or not at all.
- **Reaching the dashboard from Windows:** the gateway binds `127.0.0.1:42617`
  inside WSL; WSL2 forwards localhost, so open `http://localhost:42617` in the
  Windows browser. No tunnel needed on the same box (use the SSH tunnel only to
  reach it from a *different* machine).
- **Clock:** WSL can drift after a host sleep; set the zone with `timedatectl`
  (step 4) and it resyncs on resume.
- **Paths:** the source `$HOME` (`/Users/...`) rewrites to the WSL `$HOME`
  (`/home/<user>`), same as any Linux box (step 6). Keep everything inside the WSL
  filesystem (`~`), not `/mnt/c/...` — the Windows-mounted drives are slow and have
  different permission semantics that break `chmod 600` on `.secret_key`.

---

## 9. Verify

```bash
# (a) secrets decrypt — no errors here:
journalctl --user -u zeroclaw.service -n 200 --no-pager \
  | grep -iE 'enc2: decryption failed|wrong .secret_key' \
  && echo 'SECRET KEY MISMATCH — fix before proceeding' || echo 'no decryption errors'
zeroclaw doctor ; zeroclaw status
zeroclaw agent -a gh_notif -m "reply: gh_notif online"

# (b) Discord connected:
journalctl --user -u zeroclaw.service -f | grep -i discord     # look for gateway READY/connected
#   then from the authorized user, in Discord:  /gh-draft show #<n>
#   (global slash commands can take ~1h; guild-scope for instant)

# (c) poll tick is incremental, NOT a full re-draft (proves seen.tsv carried over):
SKILL="$HOME/.zeroclaw/skills/github-notification-orchestrator"
STATE="$HOME/.zeroclaw/workspace/gh-notif/state"
BINDER="$HOME/.zeroclaw/workspace/gh-notif/triage/$(date +%F)" ; mkdir -p "$BINDER"
bash "$SKILL"/scripts/notifications_delta.sh delta "$STATE" "$BINDER"
wc -l "$BINDER"/new.tsv 2>/dev/null || echo "no new.tsv (empty delta — expected)"
```

If `new.tsv` lists your **entire** inbox, `seen.tsv` didn't transfer — restore it
from the tarball before the poll cron runs, or the first tick re-drafts everything.

---

## 10. Rollback

Read-only on the source, additive on the target — fully reversible:

1. `systemctl --user disable --now zeroclaw.service` (stops it owning the bot).
2. `loginctl disable-linger "$USER"` (optional).
3. On the **source host**, restart its daemon to reclaim the single-daemon role.
4. If a config edit went wrong on the target, restore `config.toml.premigrate`.
5. No upstream side effects are possible — the system is draft-only and the ship
   cron stayed `enabled = false`, so there is nothing to un-post.
