# Synthesis: Agent Frameworks, Harness Engineering, and Pyre

> Connecting the research on Jido, Symphony, Harness Engineering, and OpenClaw to Pyre's architecture and future direction.

## The Landscape at a Glance

| Project | What It Is | Layer It Operates At |
|---------|------------|---------------------|
| **Pyre** | Multi-agent pipeline for Phoenix feature development | Task execution (one-shot, CLI-driven) |
| **Jido** | Pure functional agent framework for Elixir/OTP | Agent primitives and runtime |
| **Symphony** | Project work orchestration daemon | Project management (issue tracker -> agent -> PR) |
| **OpenClaw** | Personal AI assistant with system access | General-purpose autonomous agent |
| **Harness Engineering** | Design discipline for agent environments | Meta-pattern / methodology |

These are not competing -- they operate at different layers of the stack.

## Where Pyre Sits Today

Pyre is a **5-stage multi-agent pipeline** that converts a feature request into implemented Phoenix code:

```
Feature Request
  -> Product Manager (requirements)
  -> Designer (UI/UX spec)
  -> Programmer (implementation)
  -> Test Writer (tests)
  -> Code Reviewer (approve/reject -> loop)
```

**Strengths:**
- Clean stage-based orchestration with review loop
- Persona-driven agents with domain-specific prompts
- Artifact system for transparency and traceability
- Leverages existing generators (Igniter-based) as "tools"
- Minimal dependencies, easy to understand

**Current limitations (not criticisms -- it's v0.1.0):**
- One-shot execution (no persistence between runs)
- Sequential-only pipeline (no parallel stages)
- Claude CLI as the only agent runtime
- No structured state management for agents
- No signal/event system between stages
- No mechanical enforcement of output quality beyond the review loop

## How Jido Could Enhance Pyre

Jido is the most directly relevant project to Pyre. Both are Elixir-native and OTP-aware. Here's how Jido's primitives map to Pyre's needs:

### High-Value Alignments

| Pyre Concept | Current Implementation | With Jido |
|---|---|---|
| **Stages** | Structs in `orchestrator.ex` | Jido Actions with schema-validated inputs/outputs |
| **Personas** | Markdown files loaded at runtime | Could become Jido Plugins with validated state |
| **Orchestrator** | Custom `run/2` function | Jido Agent with FSM strategy (stages as states) |
| **Review loop** | Hardcoded 3-cycle loop | FSM transitions: `implementing -> reviewing -> approved/rejected` |
| **Artifact passing** | File-based read/write | Jido Signals carrying structured data between stages |
| **Runner** | Shell-out to `claude` CLI | Jido Action wrapping LLM calls via `jido_ai` |

### What Jido Brings That Pyre Lacks

1. **Schema validation** -- Jido validates agent state and action parameters. Pyre currently trusts that artifacts contain the right content. With Jido, you could validate that the programmer stage actually produced implementation files, that the reviewer's verdict is parseable, etc.

2. **FSM strategy** -- The review loop is naturally a finite state machine. Jido makes this explicit with defined transitions and guards, rather than the current `if approve? do break else continue` logic.

3. **Signal system** -- Inter-stage communication through CloudEvents-based signals rather than file reads. This enables:
   - Event-driven triggers (stage completion fires a signal)
   - Observability (subscribe to signals for logging/metrics)
   - Future extensibility (external systems can listen/respond)

4. **Directive-based effects** -- Instead of the runner directly shelling out, LLM calls become directives that the runtime executes. This makes the pipeline testable without actually calling LLMs.

5. **Multi-agent runtime** -- Jido's AgentServer + instance supervision could enable parallel pipelines, concurrent stages, and agent lifecycle management.

### Potential Risks of Adopting Jido

- **Complexity budget**: Jido is a substantial framework. Pyre's simplicity is a feature.
- **Learning curve**: The Elm/Redux mental model is powerful but non-obvious to Elixir developers used to GenServer patterns.
- **Version maturity**: Jido is at v2.0.0 but the ecosystem (jido_ai, etc.) is still young.
- **Abstraction overhead**: For a 5-stage pipeline, Jido's full signal/directive/strategy system may be overengineered.

### Recommended Approach: Incremental Adoption

Rather than rewriting Pyre on Jido, consider adopting specific pieces:

1. **Start with Actions** -- Wrap each stage's execution as a Jido Action. This gets you schema validation and testability without restructuring the pipeline.

2. **Add the FSM strategy** -- Model the orchestrator as a Jido Agent with FSM strategy. The review loop becomes explicit state transitions.

3. **Later: Signals for observability** -- Once the core works, add signal emission for pipeline events. This enables dashboards, metrics, and external integrations.

4. **Optional: jido_ai for LLM calls** -- Replace the claude CLI shell-out with jido_ai's structured LLM interface. This adds model flexibility and structured output support.

## What Symphony Teaches Pyre

Symphony and Pyre share DNA (both Elixir, both orchestrate coding agents), but Symphony operates at a higher level:

### Patterns Worth Borrowing

1. **WORKFLOW.md as configuration** -- Symphony's single-file configuration is cleaner than scattered config. Pyre could consolidate persona selection, stage ordering, model choices, and tool permissions into a single `WORKFLOW.md` per project.

2. **Workspace isolation** -- Symphony creates per-issue directories with hook lifecycle. Pyre already has per-run artifact directories, but could add hooks (`before_run`, `after_run`) for project-specific setup.

3. **Retry with context** -- Symphony passes failure context to retry attempts. Pyre's review loop could similarly pass the reviewer's specific criticisms to the programmer stage on retry (it partially does this via artifacts, but could be more structured).

4. **Spec-driven design** -- Symphony ships a `SPEC.md` separate from the implementation. As Pyre grows, separating the spec from the code would help others build compatible implementations.

### Patterns That Don't Apply (Yet)

- **Issue tracker integration** -- Pyre is CLI-driven; it doesn't need to poll trackers
- **Long-running daemon mode** -- Pyre is one-shot by design
- **Concurrent agent management** -- Single pipeline for now

## How Harness Engineering Applies to Pyre

Harness engineering is the most broadly applicable concept. Pyre is itself a harness -- it structures how agents do work. The question is how well it embodies the discipline.

### Already Present in Pyre

| Harness Concept | Pyre Implementation |
|---|---|
| Documentation as context | Persona files provide agent instructions |
| Structured workflow | 5-stage pipeline with defined order |
| Quality gates | Code reviewer as evaluation gate |
| Artifact traceability | Timestamped run directories with versioned files |
| Tool constraints | Per-stage tool allowlists |

### Gaps to Address

| Harness Concept | Missing in Pyre |
|---|---|
| **Mechanical invariants** | No CI-level enforcement of agent output quality |
| **Application legibility** | Agents write code but don't observe the running app |
| **Entropy management** | No detection of pattern proliferation across runs |
| **Cross-run learning** | Each run starts fresh; no memory of past successes/failures |
| **Metrics & observability** | Timing exists but no structured metrics dashboard |
| **Safety rails** | Permission modes exist but no egress control or audit |

### Highest-Impact Harness Improvements for Pyre

1. **Application legibility**: After the programmer stage, have an agent boot the Phoenix app and verify it compiles/loads. This closes the feedback loop that harness engineering emphasizes.

2. **Mechanical validation**: Add a stage (or enhance the reviewer) that runs `mix compile --warnings-as-errors`, `mix test`, and `mix credo`. Make these results available to the review loop.

3. **Cross-run memory**: Store successful patterns and common failures in a knowledge base that personas can reference. This is where the "plans as repository artifacts" concept from harness engineering applies.

## Open Questions for Discussion

1. **Adoption depth**: Should Pyre adopt Jido as a dependency, or extract specific patterns (like FSM, schema validation) and implement them independently? The tradeoff is between leverage and coupling.

2. **Pipeline flexibility**: Should Pyre's stage pipeline be configurable per-project (like Symphony's WORKFLOW.md), or is the opinionated 5-stage flow a feature?

3. **Agent runtime**: Currently Pyre shells out to the `claude` CLI. Should it move to API-based LLM calls (via `jido_ai` or directly via the Anthropic API)? This would enable structured outputs, better error handling, and model flexibility.

4. **Scope expansion**: Should Pyre stay focused on Phoenix feature generation, or become a more general-purpose Elixir agent orchestration tool? Jido and Symphony suggest the tooling layer and orchestration layer could be separated.

5. **Feedback loops**: What's the right level of application legibility for Pyre? Should agents be able to observe the running Phoenix app (like Symphony's DevTools integration), or is compile/test validation sufficient?

6. **Persistence model**: Should Pyre maintain state across runs? If so, what state -- successful patterns, common failures, project conventions, or full run history?

## Recommended Reading Order

1. [Harness Engineering](research-harness-engineering.md) -- The "why" and design philosophy
2. [Jido](research-jido.md) -- The most relevant Elixir-native framework
3. [Symphony](research-symphony.md) -- Higher-level orchestration patterns
4. [OpenClaw](research-openclaw.md) -- Personal agent patterns (less directly relevant)
