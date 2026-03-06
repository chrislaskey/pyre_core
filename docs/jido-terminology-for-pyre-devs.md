# Jido Terminology: A Guide for Pyre Developers

> Translating Jido concepts into what you already know from building Pyre.

## The Core Loop, Side by Side

**Pyre today:**
```
Feature Request (string)
  -> Stage 1: Product Manager reads request, writes markdown artifact
  -> Stage 2: Designer reads prior artifacts, writes markdown artifact
  -> Stage 3: Programmer reads prior artifacts, writes code + markdown artifact
  -> Stage 4: Test Writer reads prior artifacts, writes tests + markdown artifact
  -> Stage 5: Code Reviewer reads all artifacts, writes verdict
  -> If REJECT: loop stages 3-5 (up to 3 cycles)
```

**Same thing in Jido terms:**
```
Signal("feature.requested", %{description: "..."})
  -> Agent receives signal
  -> FSM state: "planning" -> runs ProductManagerAction
  -> FSM state: "designing" -> runs DesignerAction
  -> FSM state: "implementing" -> runs ProgrammerAction
  -> FSM state: "testing" -> runs TestWriterAction
  -> FSM state: "reviewing" -> runs CodeReviewerAction
  -> If REJECT: FSM transitions back to "implementing"
  -> If APPROVE: FSM transitions to "complete"
```

The data that flows between stages (your markdown artifacts) becomes structured data in signal payloads and agent state, rather than files on disk.

---

## Term-by-Term Breakdown

### Schema-Validated Actions

**What you have now:** Each stage in `orchestrator.ex` is a `Stage` struct with fields like `name`, `persona`, `reads`, `writes`, `tools`, `model`. But there's no validation that the output of one stage is what the next stage expects. If the Product Manager produces malformed output, the Designer just gets bad input and does its best.

**What Jido adds:** An Action is a module with a declared schema (like an Ecto changeset for function parameters). Before the action's code runs, Jido validates that the inputs match the schema. If they don't, you get a structured error instead of garbage-in-garbage-out.

```elixir
# Pyre today: the stage just shells out to claude with a prompt
# and trusts the output is correct
%Stage{name: :product_manager, writes: "01_requirements.md"}

# Jido Action: declares exactly what it expects and produces
defmodule ProductManagerAction do
  use Jido.Action,
    name: "product_manager",
    schema: [
      feature_description: [type: :string, required: true],
      project_context: [type: :string, default: ""]
    ]

  def run(params, _context) do
    # params.feature_description is guaranteed to be a string
    # If someone passed an integer, we'd never get here
    {:ok, %{requirements: "...", user_stories: [...]}}
  end
end
```

**Why it matters:** When you have multiple flows (PR creation, PR review, demo UIs) reusing the same agent actions, schema validation catches integration bugs early. You know the QA Reviewer action always receives the same shaped input regardless of which flow calls it.

---

### FSM-Based Orchestration

**What you have now:** The orchestrator in Pyre has a hardcoded list of stages that run in order, with a special `review_loop` function that re-runs stages 3-5 on rejection. The flow logic is imperative -- `Enum.reduce` over stages, then a recursive function for the loop.

**What "FSM" means:** FSM = Finite State Machine. Instead of a list of stages with loop logic, you define **states** and **allowed transitions** between them:

```
planning -> designing -> implementing -> testing -> reviewing
                                ^                       |
                                |______(REJECT)_________|
                                                        |
                                                   (APPROVE)
                                                        |
                                                        v
                                                    complete
```

**In Jido:**

```elixir
defmodule FeatureAgent do
  use Jido.Agent,
    name: "feature_builder",
    strategy: {Jido.Agent.Strategy.FSM,
      initial_state: "planning",
      transitions: %{
        "planning"      => ["designing"],
        "designing"     => ["implementing"],
        "implementing"  => ["testing"],
        "testing"       => ["reviewing"],
        "reviewing"     => ["implementing", "complete"],  # can go back!
        "complete"      => []  # terminal
      }
    }
end
```

**What changes:**
- The review loop isn't special code anymore -- it's just a transition from "reviewing" back to "implementing"
- Invalid transitions are rejected automatically (can't skip from "planning" to "reviewing")
- You can query the current state at any time: `strategy_snapshot(agent).details[:fsm_state]`
- Adding a new flow (like "PR review") means defining a different set of states and transitions, not writing different loop logic

**What stays the same:** The pipeline still runs stages in order. You're just declaring the valid orderings instead of coding them imperatively.

---

### Signal System for Inter-Stage Communication

**What you have now:** Stages communicate through markdown files on disk. The orchestrator's `Persona.build_prompt/4` reads previous artifacts and assembles them into a prompt for the next stage. Artifact passing looks like:

```elixir
%Stage{name: :designer, reads: ["01_requirements.md"]}
# persona.ex reads the file, concatenates it into the prompt
```

**What a "signal" is:** A signal is a structured message envelope (based on the CloudEvents spec). Instead of writing a file and having the next stage read it, one stage emits a signal containing the data, and the next stage receives it.

```elixir
# Instead of writing "01_requirements.md" to disk...
# The ProductManager action returns data:
{:ok, %{
  requirements: "Users need to...",
  user_stories: ["As a user, I want to..."],
  data_model: %{entities: ["Product", "Category"]}
}}

# ...which flows into the agent's state automatically.
# The next action (Designer) reads it from context:
def run(params, context) do
  requirements = context.state[:requirements]
  user_stories = context.state[:user_stories]
  # Use these to build the design prompt
end
```

**The key difference:** Files on disk are untyped strings. Signals carry structured data (maps, lists, typed fields). You can pattern-match on them, validate them, route them conditionally.

**What you'd keep:** You might still want to write artifacts to disk for human inspection. But the inter-stage data flow would be in-memory structured data, with file writes as a side effect for observability.

**Signals also enable:**
- **Observability** -- subscribe to signals to log/metrics what's happening in the pipeline
- **Routing** -- send different signal types to different handlers (e.g., "review.approve" vs "review.reject" go to different actions)
- **Decoupling** -- the ProductManager doesn't need to know which stage reads its output; it just emits a signal

---

### Directive-Based Effects (Separating "What To Do" from "Doing It")

**What you have now:** When the Runner executes a stage, it directly shells out to the `claude` CLI:

```elixir
# runner.ex
System.cmd("/bin/sh", ["-c", command], into: IO.stream(:stdio, :line))
```

The action (calling claude) and the effect (spawning a process, writing output) are tangled together.

**What "directives" mean:** Instead of doing the side effect, an action **describes** what should happen and returns that description as data:

```elixir
# Without directives (current Pyre approach):
def run_stage(stage) do
  output = System.cmd("claude", args)      # DOES the thing
  File.write!(artifact_path, output)       # DOES another thing
  send(next_stage, {:artifact, output})    # DOES yet another thing
end

# With directives (Jido approach):
def run(params, context) do
  {:ok, %{requirements: "..."}, [
    Directive.emit(signal),                # DESCRIBES: "emit this signal"
    # The action itself doesn't emit anything.
    # It returns a struct that says "someone should emit this signal."
  ]}
end
# The runtime (AgentServer) later executes the directives.
```

**Why this matters:**

1. **Testing:** You can test your action logic without any side effects. Just call `cmd/2`, get back data, and assert on it. No mocking, no process spawning, no file system.

   ```elixir
   test "product manager produces requirements" do
     agent = FeatureAgent.new()
     {agent, directives} = FeatureAgent.cmd(agent, {ProductManagerAction, %{feature: "..."}})

     assert agent.state.requirements != nil
     assert length(directives) == 1  # should emit one signal
   end
   ```

2. **Replaceability:** The runtime that executes directives can be swapped. In tests, directives are just data to assert on. In production, the AgentServer actually sends messages, spawns processes, etc. In a dry-run mode, you could log directives without executing them.

3. **Visibility:** You can inspect the list of directives before they execute. This is like having a preview of all the side effects an action will cause.

**Analogy:** Think of it like Ecto.Multi. Instead of running each database operation immediately, you build up a list of operations and then execute them all at once. Directives are like that, but for arbitrary side effects (emit signals, spawn agents, schedule work, etc.).

---

## Putting It All Together: Pyre's Feature Flow in Jido

Here's how the full picture maps:

```
┌─────────────────────────────────────────────────────┐
│  FeatureAgent (FSM Strategy)                        │
│                                                     │
│  State: %{                                          │
│    feature: "Build a products page",                │
│    requirements: nil,    # filled by PM action      │
│    design: nil,          # filled by Designer       │
│    implementation: nil,  # filled by Programmer     │
│    tests: nil,           # filled by Test Writer    │
│    verdict: nil           # filled by Reviewer       │
│  }                                                  │
│                                                     │
│  FSM: planning → designing → implementing →         │
│       testing → reviewing → complete                │
│                    ↑              ↓ (REJECT)         │
│                    └──────────────┘                  │
│                                                     │
│  Each transition runs a Jido Action:                │
│    planning→designing:     ProductManagerAction      │
│    designing→implementing: DesignerAction            │
│    implementing→testing:   ProgrammerAction          │
│    testing→reviewing:      TestWriterAction          │
│    reviewing→complete:     (approval check)          │
│    reviewing→implementing: (rejection loop)          │
│                                                     │
│  Plugins:                                           │
│    PersonaPlugin   - loads markdown persona files   │
│    ArtifactPlugin  - writes run artifacts to disk   │
│    StreamingPlugin - streams LLM output to terminal │
└─────────────────────────────────────────────────────┘
```

---

## Your Reusable Agents Vision

You want the QA Reviewer to work across multiple flows. In Jido, this becomes:

```elixir
# The Action is reusable -- it doesn't know which flow it's in
defmodule QAReviewerAction do
  use Jido.Action,
    name: "qa_reviewer",
    schema: [
      code_to_review: [type: :string, required: true],
      review_criteria: [type: {:list, :string}, default: []]
    ]

  def run(params, context) do
    persona = context.state.persona  # loaded from PersonaPlugin
    # ... call LLM with persona + code_to_review
    {:ok, %{verdict: "APPROVE", feedback: "..."}}
  end
end

# Flow 1: Feature Builder
defmodule FeatureBuildAgent do
  use Jido.Agent,
    name: "feature_builder",
    plugins: [PersonaPlugin, ArtifactPlugin],
    signal_routes: [
      # ... other routes ...
      {"review.requested", QAReviewerAction}   # <-- reused
    ]
end

# Flow 2: PR Review
defmodule PRReviewAgent do
  use Jido.Agent,
    name: "pr_reviewer",
    plugins: [PersonaPlugin],
    signal_routes: [
      {"pr.review", QAReviewerAction}          # <-- same action, different flow
    ]
end

# Flow 3: Demo UI Builder
defmodule DemoUIAgent do
  use Jido.Agent,
    name: "demo_builder",
    plugins: [PersonaPlugin, ArtifactPlugin],
    signal_routes: [
      # ... other routes ...
      {"demo.review", QAReviewerAction}        # <-- same action again
    ]
end
```

The QA Reviewer's persona, behavior, and learnings are in the Action + PersonaPlugin. The flows just wire it in where they need it.

---

## On Streaming: You Keep It (It Gets Better)

**Current approach:** `System.cmd("claude", args, into: IO.stream(:stdio, :line))` streams claude CLI output line-by-line.

**API approach with jido_ai / ReqLLM:**

```elixir
{:ok, response} = ReqLLM.stream_text("anthropic:claude-sonnet-4-20250514", prompt)

ReqLLM.StreamResponse.tokens(response)
|> Stream.each(fn token -> IO.write(token) end)  # token-by-token output
|> Stream.run()
```

**What improves:**
- **Granularity**: Token-by-token instead of line-by-line
- **Structure**: You get typed events (`text_delta`, `tool_call`, `thinking_delta`) not just raw text
- **Metadata**: Token usage, finish reason, rate limits available concurrently without blocking the stream
- **Flexibility**: Stream to terminal, to a Phoenix LiveView, to a log file -- all simultaneously via `Stream.each`

The Anthropic API natively supports SSE (Server-Sent Events) streaming. ReqLLM uses Finch (not Req) under the hood specifically because Finch handles long-lived SSE connections well. So you get real-time streaming that's actually more responsive than the CLI approach.

---

## Glossary Quick Reference

| Jido Term | Pyre Equivalent | Plain English |
|-----------|----------------|---------------|
| **Agent** | The overall pipeline | A stateful entity that receives messages and produces effects |
| **Action** | A stage's execution logic | A validated, reusable unit of work (function with typed inputs/outputs) |
| **Signal** | Markdown artifact content | A structured message that carries data between stages |
| **Directive** | `System.cmd` / `File.write!` calls | A description of a side effect, executed by the runtime later |
| **FSM Strategy** | `review_loop` + stage ordering | A state machine that controls which transitions are valid |
| **Plugin** | Persona file + associated logic | A reusable bundle of state, actions, and behavior |
| **AgentServer** | `Orchestrator.run/2` | The OTP process that hosts an agent and executes directives |
| **Signal Router** | `%Stage{reads: [...]}` | Rules for which signals go to which actions |
| **Schema** | (implicit / trust-based) | Declared types for action inputs and outputs |
| **cmd/2** | Running a single stage | The pure function that processes an action and returns new state + directives |
