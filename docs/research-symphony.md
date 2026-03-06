# OpenAI Symphony: Project Work Orchestration

> Research notes on OpenAI's Symphony project and its relevance to agent orchestration.

## Overview

Symphony is **not** a general-purpose multi-agent SDK. It is a **project work orchestration service** -- a long-running daemon that monitors an issue tracker, spawns isolated coding agent sessions, and manages their full lifecycle.

| Field | Value |
|-------|-------|
| Language | Elixir (94.9%) |
| License | Apache 2.0 |
| Status | Engineering preview / prototype |
| Stars | ~6,900 |
| Created | February 2026 |

> "Turns project work into isolated, autonomous implementation runs, allowing teams to manage work instead of supervising coding agents."

The mental model is closer to **CI/CD for coding agents** than to a chatbot orchestrator.

## Architecture: Six Layers

### 1. Policy Layer
A repository-owned `WORKFLOW.md` file with YAML front matter (configuration) and markdown body (prompt template). Single source of truth for all behavior. Hot-reloadable.

### 2. Configuration Layer
Typed getters parsing YAML front matter, resolving environment variables, providing defaults for poll intervals, concurrency, timeouts, sandbox policies.

### 3. Coordination Layer
The **Orchestrator** -- owns the polling loop, in-memory state, dispatch decisions, concurrency control, and retry logic with exponential backoff.

### 4. Execution Layer
**Workspace Manager** (filesystem isolation per issue) + **Agent Runner** (subprocess management, prompt rendering, JSON-RPC event streaming over stdio).

### 5. Integration Layer
**Issue Tracker Client** that normalizes tracker payloads. Currently only Linear, but adapter-based for extensibility (Jira, GitHub Issues, etc.).

### 6. Observability Layer
Structured logging, terminal status dashboard, optional Phoenix LiveView web dashboard with REST API.

## Orchestration Model: Poll-Reconcile-Dispatch

1. **Poll**: Fetch active issues from Linear (filtered by state, sorted by priority)
2. **Reconcile**: Check running agents against issue state; stop agents whose issues moved to terminal states
3. **Process Retry Queue**: Dispatch retries whose backoff timers have elapsed
4. **Select Candidates**: Pick eligible issues, respecting `max_concurrent_agents` (default 10) and per-state limits
5. **Dispatch**: Create/reuse workspace, run hooks, render prompt, launch Codex subprocess, stream events

## Key Design Decisions

### No Inter-Agent Handoffs
Each issue maps to exactly one agent session. Handoffs are between orchestrator and agents, or from agents to humans via issue tracker state transitions.

### WORKFLOW.md as Control Plane
All behavior driven by a single markdown file. Hot-reloadable -- changes apply dynamically without restarting active agents.

### Workspace Isolation
Every issue gets its own filesystem directory. Strong isolation without containers.

### Hook Lifecycle
Four hook points: `after_create`, `before_run`, `after_run`, `before_remove`. Configurable timeouts and failure semantics.

### Prompt Construction with Retry Context
On retry, the prompt includes previous error summary, enabling agent adaptation.

### Token Accounting
Full input/output/total token tracking per session and globally, plus rate-limit awareness.

### Spec-Driven Development
Ships as a language-agnostic `SPEC.md` with Elixir reference implementation. Teams can build conformant implementations in any stack.

## Comparison to Other Frameworks

| Dimension | Symphony | Agents SDK / Swarm | LangGraph | CrewAI |
|-----------|----------|-------------------|-----------|--------|
| **Purpose** | Autonomous coding orchestration | Conversational agent routing | Stateful workflow graphs | Role-based collaboration |
| **Agent model** | One agent per work item | Agents as prompt+tools+handoffs | Nodes in a graph | Agents with roles/goals |
| **Handoffs** | Orchestrator-to-agent only | Agent-to-agent in conversation | Edge transitions | Task delegation |
| **Scope** | Full SDLC (issue -> PR -> merge) | Single conversation/task | Arbitrary workflows | Task completion |
| **Concurrency** | First-class (N parallel, per-state limits) | Not primary | Parallel nodes | Sequential/parallel tasks |
| **Recovery** | Exponential backoff, reconciliation | Not built-in | Checkpointing | Not built-in |

## Key Insight

Symphony operates at the **project management layer** -- replacing the human loop of triaging issues, assigning them, and reviewing work. Other frameworks operate at the **conversation or task layer**. Symphony is not about making agents talk to each other; it's about making agents do sustained, isolated coding work at scale.

## Relevance to Pyre

Both Pyre and Symphony use Elixir and share the concept of orchestrating coding agents through defined stages. Key differences:

- Symphony is a **long-running daemon** that polls an issue tracker; Pyre is a **one-shot Mix task**
- Symphony uses Codex as its agent runtime; Pyre uses the Claude CLI
- Symphony's unit of work is an issue; Pyre's is a feature request passed as a CLI argument
- Symphony has first-class concurrency (many issues in parallel); Pyre runs one pipeline at a time
- Symphony's `WORKFLOW.md` is analogous to Pyre's persona files
