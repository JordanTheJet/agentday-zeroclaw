# Model Selection Rationale

This system is multi-agent: an **orchestrator** plans the inbox, a fleet of
**per-notification sub-agents** draft responses, a **verifier** adversarially
gates the high-stakes drafts, and a **summarizer** assembles the digest. Each
role has a different difficulty, blast radius, and call volume — so each gets a
different model.

> **Governing principle:** match model strength to the task's difficulty *and
> blast radius*; use the cheapest model that clears the bar; reserve the
> expensive tiers for reasoning that is deep **and** where a mistake is costly.
> Spending Opus on a job Haiku does correctly is waste; spending Haiku on a code
> review is a false economy that ships a confidently-wrong draft.

## The model menu (per 1M tokens)

Use the alias when spawning sub-agents. Prices are the Anthropic API list rates.

| Tier | Alias | Input | Output | Character |
|---|---|---|---|---|
| Fable 5 | `fable` | $10 | $50 | Most intelligent; a tier above Opus. Reserve for the genuinely hardest reasoning. |
| Opus 4.8 | `opus` | $5 | $25 | Most capable Opus; state-of-the-art code + long-horizon agentic reasoning. |
| Sonnet 4.6 | `sonnet` | $3 | $15 | Best speed/intelligence balance. The high-volume workhorse. |
| Haiku 4.5 | `haiku` | $1 | $5 | Fastest, cheapest. Mechanical, well-structured, speed-critical tasks. |

Output tokens dominate cost here (drafts are output-heavy). The ratios that drive
the assignments: **Opus output is 5× Haiku and 3× Sonnet's; Sonnet output is 60%
of Opus.** So routing every sub-agent to Opus "to be safe" would roughly 3–5× the
output bill of the high-volume roles for no quality gain on the structured ones —
which is the whole point of per-role selection.

## Per-role assignment

| Role | Model | Why this tier (and not one lower/higher) |
|---|---|---|
| **Orchestrator** (planner, main loop) | **opus** | Plans a heterogeneous 100+ item inbox and routes every ambiguous notification; misroutes cascade to every downstream sub-agent. The one place to pay for the strongest general reasoning. Not Fable: planning is hard but not frontier. |
| **pr-review-responder** | **opus** | Reads diffs and reasons about correctness/security — highest blast radius. A plausible-but-wrong review the user pastes is worse than none, and code reasoning is where Opus's lead over Sonnet is largest. Bump a 2,000-line or security-critical PR to **fable**. |
| **verifier** | **opus** | Refuting a code/CI claim against source needs the same depth that produced it. Runs on only a few items per run, so cost stays bounded — and it is the cheapest place to catch a confident-but-wrong draft before the user acts. |
| **issue-responder** | **sonnet** | Classify + label + draft a clarifying reply — well-structured and high-volume. Sonnet is the cost/quality sweet spot; Opus would triple the cost for little gain on a structured task. Not Haiku: judging duplicate-vs-distinct needs real comprehension. |
| **mention-responder** | **sonnet** | Drafting a contextual reply needs good language + light reasoning, not code analysis — at 60% of Opus's output cost. |
| **author-activity-responder** | **sonnet** | Summarize what changed on your own thread and propose the next move: summarization + light judgment. |
| **ci-failure-investigator** | **sonnet** | Parse CI logs to the root-cause line + failing test — pattern extraction with some reasoning. Escalate a non-obvious failure (flaky, cross-crate, miscompile) to **opus**. Not Haiku: logs are noisy and the root cause is rarely the last red line. |
| **daily-summarizer** | **haiku** | Collating the written reports into a sorted, linked index is mechanical — and a *script* (`build_index.py`) does the sorting/linking deterministically, so the model only writes a short lede over pre-structured data. The cheapest fast model is ideal; Opus here is pure waste. |

## Overrides

Each profile's `model:` is a **recommendation passed to the Agent tool**, not a
hard binding. Override per item when an instance is unusually hard (a giant or
security-sensitive PR → `fable`; a gnarly CI failure → `opus`) or unusually
trivial (a "thanks, LGTM" mention → `haiku`). The table is the default that's
right most of the time; the override is how you spend more only where a specific
item earns it.

## Thinking & effort

Sub-agents use adaptive thinking. Prefer **high** effort on the Opus
`pr-review-responder` and `verifier` (review is intelligence-sensitive; a missed
bug is the costly error), **medium** on the Sonnet roles, and none on the Haiku
summarizer (its work is mechanical and Haiku doesn't expose the effort knob).

## Deployment note (ZeroClaw)

In the Claude Code fan-out, each sub-agent runs at its profile's recommended
model via the Agent tool's `model` override — the per-role table above applies
directly. In the **ZeroClaw cron deployment** (`gh_notif` agent), a single agent
currently drafts each item at **one** model (`claude-sonnet-4-6`); to get true
per-profile models there, define one ZeroClaw agent per profile and delegate to
them via `DelegateTool` (a documented future enhancement). The orchestration
judgment (the main loop) stays on **opus** in both modes.
