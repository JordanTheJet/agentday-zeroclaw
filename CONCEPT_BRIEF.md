# Concept Brief — GitHub Notification Orchestrator

**Track 3: Best Multi-Agent / Skill Composition** · built on [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) · repo: `JordanTheJet/agentday-zeroclaw`

## The problem
A maintainer's GitHub inbox is a firehose — 145 unread notifications is a normal
morning. Figuring out *which PR needs a review, who is blocked on you, which CI
broke, and what is a duplicate* is high-context manual work that eats the start
of every day.

## What we built
A **draft-only, multi-agent system** that works the *entire* inbox and hands you
a morning briefing. It **plans** the inbox, **fans out one sub-agent per
notification** to draft a response, runs an **adversarial verifier** over the
high-stakes drafts, **composes with the repo's specialist skills**, and a
**summarizer** assembles a dated, priority-sorted digest. It never posts —
every output is a proposal you edit and send.

Two from-scratch [agentskills.io](https://agentskills.io)-spec skills:
- **`github-notification-orchestrator`** — the orchestrator: a planner + 7
  model-matched sub-agents + an adversarial verifier + a summarizer + bundled
  read-only/deterministic scripts.
- **`github-duplicate-check`** — a read-only "has anyone already raised this?"
  check across open *and* closed issues *and* PRs, before you file or draft.

## Why it's Track 3 (multiple agents **and** multiple skills)
- **Multi-agent orchestration:** a planner routes each notification to one of 7
  profiled sub-agents (PR review, issue, mention, authored-thread, CI failure) —
  each with its own prompt, tool allow-list, and model.
- **Agent-to-agent delegation:** a second **verifier** agent (opus) adversarially
  *refutes* the high-stakes drafts against the source before they're trusted — a
  two-layer pipeline with a quality gate, not a flat fan-out. On real data it
  caught a PR that had **regressed the build**, and two **overstatements** in
  another draft.
- **Skill composition:** it composes **5 skills** — handing PR reviews to
  `github-pr-review-session`, issue lifecycle to `github-issue-triage`, reusing
  `daily-notification-triage`'s identity helpers, and calling
  `github-duplicate-check` before drafting — all through a shared
  `tmp/handoff.md` file contract.

It's a textbook **Deep Agents** system: **planner** (`plan.md`) → **sub-agents**
(`agents/`) → **virtual filesystem** (the dated `triage/<date>/` blackboard —
agents coordinate *only* through files) → **detailed system prompt** (`SKILL.md`
+ each profile). Model selection is deliberate and documented — opus for code
review + verification, sonnet for the structured middle, haiku for mechanical
collation — in [`model-selection-rationale.md`](model-selection-rationale.md).

## Proof it works
- A real run over a **145-notification inbox** is bundled in
  [`examples/run-2026-06-27/`](.claude/skills/github-notification-orchestrator/examples/run-2026-06-27/).
- **Deployed live on a ZeroClaw instance** as a genuine, **ZeroClaw-native
  multi-agent fan-out** — no Claude Code dependency. A poll cron runs the
  orchestrator agent `gh_notif` (sonnet): it runs a read-only delta script to
  find *new* notifications, routes each by reason/type, and uses ZeroClaw's
  built-in `delegate` tool to hand it to one of **6 model-matched sub-agents** —
  `gh_notif_pr_reviewer` (opus), `gh_notif_issue`, `gh_notif_mention`,
  `gh_notif_author`, `gh_notif_ci` (sonnet) — plus an adversarial
  `gh_notif_verifier` (opus) on every PR-review draft. Delegation is
  **synchronous and serial** (one sub-agent at a time, capped at the 5 newest
  per tick); the orchestrator commits its `seen.tsv` state at the end. A daily
  9am cron delivers the digest to Discord — every line a tappable link to that
  draft's full summary in a private drafts repo — and a retention cron prunes
  old binders.
- **Verified live (2026-06-27):** one tick drafted **5 notifications routed to 5
  distinct sub-agents** (pr_reviewer, mention, ci, author, issue) plus **1
  verifier verdict** on the PR-review draft, then committed state —
  *"delegated 5 ..., verified 1, deferred 0 ... Nothing was posted."* It is
  **draft-only**: every sub-agent uses read-only `gh` and writes one local
  markdown report — nothing is ever posted, commented, reviewed, labelled,
  closed, merged, or marked read.

## Forkable
The repo is a template: fork it, `gh auth login` (it reads *your* inbox —
nothing is hardcoded), fill the placeholders in
[`deploy/zeroclaw-cron.template.toml`](deploy/zeroclaw-cron.template.toml), and
deploy. No secrets in the repo. See [`SETUP.md`](SETUP.md).
