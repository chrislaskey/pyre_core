# Harness Engineering

> Research notes on OpenAI's concept of harness engineering and its implications.

## What It Is

Harness engineering is the discipline of designing the complete operational environment -- constraints, tools, documentation, feedback loops, and enforcement mechanisms -- that enables AI coding agents to operate reliably at scale.

> "The bottleneck in agent-first software development is usually not the agent's ability to write code. It's the quality of the environment the agent operates in."

> "The horse is fast. The harness is everything."

OpenAI developed this concept while building a product entirely with Codex agents: three engineers, ~1M lines of code, ~1,500 PRs in five months -- an average of 3.5 PRs per engineer per day with no manually typed code.

## Harness Engineering vs. Prompt Engineering

| Dimension | Prompt Engineering | Harness Engineering |
|---|---|---|
| **Scope** | Single model call | Entire operational environment |
| **Focus** | Linguistic precision | Structural enforcement, feedback loops |
| **Timeframe** | Immediate output quality | Long-term maintainability |
| **Mechanism** | Text refinement | Mechanical invariants, CI, tooling |
| **Priority** | Refine the prompt | "Invest first in documentation infrastructure, not prompt engineering" |

The quality of an agent's output is bounded by the quality of the context it operates in, not the cleverness of the prompt.

## Six Key Concepts

### 1. Repository-Resident Knowledge as Ground Truth

Knowledge lives in the repo, not in Slack, Docs, or heads. The `AGENTS.md` standard:

- Small entry point (~100 lines) pointing to deeper docs
- Progressive disclosure: maps rather than manuals
- Mechanically verifiable to prevent staleness
- The OpenAI team used **88 AGENTS.md files** across subsystems

### 2. Architectural Constraints as Mechanical Invariants

Documentation alone fails because agents replicate whatever patterns exist -- including bad ones. Solution: move rules into enforced code checks.

- Layered domain architecture: `Types -> Config -> Repo -> Service -> Runtime -> UI`
- Dependency direction enforced at CI level
- Custom linters include remediation instructions (teaching agents while they work)

### 3. Application Legibility for Agents

Making running apps directly observable eliminates human QA as bottleneck:

- **Per-worktree booting**: Isolated git worktrees per agent task
- **Chrome DevTools Protocol**: Agents capture DOM, screenshots, navigate UIs
- **Ephemeral observability stacks**: Isolated logs, metrics, traces per worktree

### 4. Autonomous Development Loops

Given a single prompt, agents can: validate state, reproduce bugs, record demos, implement fixes, validate via UI, open PRs, respond to reviews, remediate build failures, escalate only when judgment is required.

### 5. Entropy Management ("AI Slop" Prevention)

Agent code tends toward patterns that proliferate because they exist, not because they're optimal. Solution: "Golden Principles" -- opinionated, mechanical rules in the repo.

- Prefer shared utilities over hand-rolled helpers
- Validate at boundaries, not via shape-probing
- Background tasks identify deviations and open refactoring PRs

### 6. Plans as Repository Artifacts

Execution plans are version-controlled in the repo, not in external PM tools. Later agents can reason about earlier decisions and rationale.

## Minimum Viable Harness Checklist

1. Small `AGENTS.md` entry point with deeper doc pointers
2. Reproducible dev environment with per-worktree isolation
3. Mechanical invariants in CI (architecture boundaries, formatting, validation)
4. Agent legibility hooks (structured logs, queryable metrics, repeatable UI driving)
5. Clear evaluation gates agents can run and interpret
6. Safety rails (least-privilege credentials, controlled egress, audit logs, rollback playbook)

## Merge Philosophy Realignment

Traditional norms become counterproductive at agent scale:

- Minimal blocking merge gates
- Short-lived pull requests
- Test flakes addressed through follow-up runs, not indefinite blocking
- Fast detection + rapid rollback rather than slow manual assurance
- **"Waiting is expensive and correction is cheap"**

## Metrics That Matter

| Category | Metrics |
|----------|---------|
| **Throughput** | Time-to-first-PR, time-to-merge, tasks/day, iterations/task |
| **Quality** | CI pass rate, defect escape rate, rollback frequency |
| **Human attention** | Review minutes/PR, escalation count |
| **Harness health** | Doc freshness violations, boundary violations, test flake rate |
| **Safety** | Blocked egress attempts, permission denials, secret-scan hits |

## Open Questions

- **Long-horizon coherence**: Does agent-generated code maintain architectural integrity over years?
- **Model capability curve**: Harness complexity should decrease as models improve
- **Brownfield retrofitting**: Success stories are largely greenfield
- **Generalizability**: The autonomous loop depends on specific repo structure

## Relevance to Pyre

Pyre already implements several harness engineering concepts:

- **Persona files** function as localized AGENTS.md-style documentation
- **Stage pipeline** provides structural enforcement of workflow
- **Review loop** creates a feedback mechanism for quality gates
- **Artifact system** makes agent outputs inspectable and traceable

Areas where harness engineering suggests Pyre could grow:

- Mechanical invariants (CI checks, linting) as part of the pipeline
- Application legibility (agents observing running apps, not just writing code)
- Entropy management (detecting and correcting pattern proliferation)
- Metrics and observability over agent runs
