# Pyre on Jido: Architecture (Implemented)

> v0.2.0 architecture after migrating from ad-hoc orchestration to Jido actions.

## What Changed

Pyre's core was rewritten from a hardcoded stage pipeline shelling out to the `claude` CLI
to a modular architecture built on Jido Actions with ReqLLM for provider-flexible LLM calls.

### Before (v0.1.0)
- `Orchestrator` with hardcoded 5 stages and imperative review loop
- `Runner` shelling out to `claude` CLI via `System.cmd`
- `Persona` loading markdown files and building string prompts
- `Artifact` managing files on disk
- Tightly coupled to Claude Code CLI

### After (v0.2.0)
- **Jido Actions** for each agent role (schema-validated, reusable across flows)
- **Flow driver** with explicit phase tracking and transition validation
- **LLM behaviour** wrapping ReqLLM (provider-agnostic, streaming support)
- **Plugins** for persona loading and artifact management
- Actions are flow-agnostic -- can be composed into different pipelines

## Current File Structure

```
lib/pyre/
  application.ex                   # OTP supervisor
  llm.ex                           # LLM behaviour + ReqLLM implementation
  llm/mock.ex                      # Mock for testing

  plugins/
    persona.ex                     # Loads persona .md files, builds message maps
    artifact.ex                    # Timestamped run dirs, versioned artifacts

  actions/
    helpers.ex                     # Shared: model resolution, LLM calling, artifact assembly
    product_manager.ex             # Requirements from feature description
    designer.ex                    # UI/UX design spec from requirements
    programmer.ex                  # Implementation (versioned artifacts on review cycles)
    test_writer.ex                 # Test coverage (versioned)
    qa_reviewer.ex                 # APPROVE/REJECT verdict (versioned, reusable)

  flows/
    feature_build.ex               # 5-phase pipeline with review loop

config/
  config.exs                       # Model aliases (fast/standard/advanced)
  runtime.exs                      # API keys from environment
```

## How Flows Work

Each flow is a module with a `run/2` function that:

1. Creates a run directory for artifacts
2. Initializes state with the input and phase tracking
3. Calls `drive/2` which pattern-matches on the current phase
4. Each phase dispatches a Jido Action, merges the result into state
5. Advances to the next phase via validated transitions
6. Loops until reaching `:complete`

```elixir
@transitions %{
  planning:       [:designing],
  designing:      [:implementing],
  implementing:   [:testing],
  testing:        [:reviewing],
  reviewing:      [:implementing, :complete],
  complete:       []
}
```

## Adding a New Flow

To create a PR Review flow that reuses the QA reviewer:

```elixir
defmodule Pyre.Flows.PRReview do
  alias Pyre.Actions.QAReviewer  # reuse the same action!

  @transitions %{
    fetching:     [:analyzing],
    analyzing:    [:reviewing],
    reviewing:    [:complete],
    complete:     []
  }

  def run(pr_url, opts \\ []) do
    # Initialize state, call drive/2
  end

  defp drive(%{phase: :reviewing} = state, context) do
    # Call QAReviewer.run/2 with the PR diff as content
    QAReviewer.run(%{...}, context)
  end
end
```

## Adding a New Action

```elixir
defmodule Pyre.Actions.SecurityReviewer do
  use Jido.Action,
    name: "security_reviewer",
    schema: [
      code: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  def run(params, context) do
    # Use the same helpers as all other actions
    model = Pyre.Actions.Helpers.resolve_model(:advanced, context)
    {:ok, sys} = Pyre.Plugins.Persona.system_message(:security_reviewer)
    # ...
  end
end
```

## Open Questions for Future Work

1. **Cross-run memory** -- Store learnings in plain files that persist between runs
2. **Parallel stages** -- Some flows could benefit from concurrent action execution
3. **LiveView streaming** -- Stream output to a Phoenix LiveView dashboard
4. **Jido AgentServer** -- Consider running flows as supervised Jido agents
