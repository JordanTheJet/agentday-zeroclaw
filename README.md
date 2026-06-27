# agentday-zeroclaw

**A forkable, multi-agent GitHub-notification assistant — Track 3: Best
Multi-Agent / Skill Composition.**

Fork this, point it at *your* GitHub account, and it works through your whole
notification inbox: it **plans** the inbox, **fans out one sub-agent per
notification** to draft a response, runs an **adversarial verifier** over the
high-stakes drafts, **composes with specialist skills**, and a **summarizer**
assembles a dated digest. It **drafts only** — it never posts, reviews, labels,
closes, or marks anything read without your explicit say-so.

Run it interactively in **Claude Code** (parallel fan-out via the Agent/Task
tool), or deploy it as scheduled agents on a **ZeroClaw** instance — a genuine,
ZeroClaw-native multi-agent fan-out with **no Claude Code dependency**: a poll
cron runs a sonnet orchestrator that uses ZeroClaw's built-in `delegate` tool to
hand each new notification to one of six model-matched sub-agents (with an opus
verifier re-checking PR-review drafts), plus a daily digest to your chat channel.

---

## What's in here

Two from-scratch [agentskills.io](https://agentskills.io)-spec skills:

| Skill | What it does |
|---|---|
| [`github-notification-orchestrator`](.claude/skills/github-notification-orchestrator/) | The orchestrator: plan → fan out → verify → digest → compose |
| [`github-duplicate-check`](.claude/skills/github-duplicate-check/) | Read-only duplicate / prior-art check (issues + PRs, by anyone) before you file or draft |

The orchestrator bundles **7 model-matched agent profiles** + 2 scheduled-agent
prompts:

| Profile | Model | Role |
|---|---|---|
| `pr-review-responder` | opus | Draft PR review notes |
| `issue-responder` | sonnet | Triage issues / assignments |
| `mention-responder` | sonnet | Draft replies to @-mentions |
| `author-activity-responder` | sonnet | Catch up on your own threads |
| `ci-failure-investigator` | sonnet | Root-cause CI failures |
| `verifier` | opus | Adversarial quality gate on high-stakes drafts |
| `daily-summarizer` | haiku | Build the dated INDEX (a script does the sorting) |

**Model choices and the reasoning behind them:** see
**[`model-selection-rationale.md`](model-selection-rationale.md)**.

The full development lifecycle (scope → design bet → eval/iteration log → deploy
→ observe) is in the orchestrator's
[`ADLC.md`](.claude/skills/github-notification-orchestrator/ADLC.md).

## How it works (Deep Agents pattern)

`plan → fan out → verify → summarize → compose` maps onto the four Deep Agents
components — **planner** (`plan.md`), **sub-agents** (`agents/`), **virtual
filesystem** (the dated `triage/<date>/` blackboard — agents coordinate only
through files), **detailed system prompt** (`SKILL.md` + each profile) — plus two
novel extensions: **skill composition** and the **adversarial verifier loop**.
Mapping in
[`deep-agents-mapping.md`](.claude/skills/github-notification-orchestrator/references/deep-agents-mapping.md).

## See it work

A real run against a 145-notification inbox is bundled at
[`examples/run-2026-06-27/`](.claude/skills/github-notification-orchestrator/examples/run-2026-06-27/):
the plan, five per-item drafts (with the verifier's verdicts), the cross-skill
hand-off, and the final `INDEX.md`.

## Use it on your own repos

It's repo-agnostic — it reads **your** notification inbox via your `gh` auth, so
there's nothing repo-specific to configure. See **[`SETUP.md`](SETUP.md)** for:

- **Claude Code** — install the skills, authenticate `gh`, say *"orchestrate my
  notifications"*. The interactive path fans out sub-agents in parallel via the
  Agent/Task tool.
- **ZeroClaw** — install the skills, apply the parameterized cron template
  [`deploy/zeroclaw-cron.template.toml`](deploy/zeroclaw-cron.template.toml)
  (fill in your home path + your chat channel id), seed the state file, and
  enable. This path runs **completely in ZeroClaw — no Claude Code dependency**.
  Piece A is a poll cron that runs the sonnet orchestrator `gh_notif`: a
  read-only delta script finds new notifications, then the orchestrator routes
  each by reason/type and uses ZeroClaw's built-in `delegate` tool to hand it to
  one of six model-matched sub-agents (`gh_notif_pr_reviewer`/opus,
  `gh_notif_verifier`/opus, `gh_notif_issue`/sonnet, `gh_notif_mention`/sonnet,
  `gh_notif_author`/sonnet, `gh_notif_ci`/sonnet) — synchronously, one at a time,
  bounded by a per-tick cap, with the opus verifier re-checking each PR-review
  draft before the script commits state. Piece C delivers a daily digest to your
  channel — and (optionally) mirrors the drafts to a **private** GitHub repo so
  every digest line is a tappable link to that draft's full summary from chat or
  mobile.

## Safety

Every agent is **read-only on GitHub** and writes drafts to local files. Nothing
is posted/reviewed/labeled/closed/marked-read without an explicit, per-action OK.
See
[`safety.md`](.claude/skills/github-notification-orchestrator/references/safety.md).
