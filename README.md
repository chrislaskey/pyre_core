## Pyre

Multi-agent LLM framework for rapid Phoenix development.

Pyre orchestrates specialized LLM agents — Product Manager, Designer,
Programmer, Test Writer, and Code Reviewer — to implement features in your
Phoenix application.

Orchestration layer runs on [Jido](https://jido.run/). Each agent is a reusable
[Jido Action](https://hexdocs.pm/jido_action/Jido.Action.html) with a persona
that guides its output. The pipeline includes a review loop that iterates until
the code reviewer approves.

### Installation

Add `pyre` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pyre, git: "https://github.com/chrislaskey/pyre", branch: "main"}
  ]
end
```

Then run the installer to copy persona files and set up the runs directory:

```bash
mix deps.get
mix pyre.install
```

This creates:

- `priv/pyre/personas/` — Editable persona files for each agent
- `priv/pyre/runs/.gitkeep` — Directory where pipeline artifacts are stored
- `.gitignore` entries to exclude run output from version control

### Configuration

Pyre calls LLM APIs directly (no CLI dependency). Set your API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

Model aliases are configured in `config/config.exs`:

```elixir
config :jido_ai,
  model_aliases: %{
    fast: "anthropic:claude-haiku-4-5",
    standard: "anthropic:claude-sonnet-4-20250514",
    advanced: "anthropic:claude-opus-4-20250514"
  }
```

To use a different provider (e.g., OpenAI), change the model alias strings
and set the corresponding API key:

```bash
export OPENAI_API_KEY=sk-...
```

```elixir
config :jido_ai,
  model_aliases: %{
    fast: "openai:gpt-4o-mini",
    standard: "openai:gpt-4o",
    advanced: "openai:o1"
  }
```

### Usage

Run the feature-building pipeline:

```bash
mix pyre.run "Build a products listing page with sorting and filtering"
```

This runs five agents in sequence:

```
Feature Request
  -> Product Manager    (requirements & user stories)
  -> Designer           (UI/UX spec with Tailwind layout)
  -> Programmer         (implementation using Phoenix conventions)
  -> Test Writer        (ExUnit tests)
  -> Code Reviewer      (APPROVE or REJECT)
       -> If REJECT: loop Programmer/TestWriter/Reviewer (up to 3 cycles)
```

Output streams to the terminal token-by-token so you can see each agent
working in real time.

#### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--fast` | `-f` | Use the fastest model for all agents |
| `--dry-run` | `-d` | Print plan without calling LLMs |
| `--verbose` | `-v` | Print diagnostic information |
| `--no-stream` | | Disable streaming (wait for complete responses) |
| `--project-dir` | `-p` | Working directory for agents (default: `.`) |

#### Artifacts

Each run creates a timestamped directory in `priv/pyre/runs/` containing:

| File | Agent | Content |
|------|-------|---------|
| `00_feature.md` | — | Original feature request |
| `01_requirements.md` | Product Manager | User stories and acceptance criteria |
| `02_design_spec.md` | Designer | UI/UX specifications |
| `03_implementation_summary.md` | Programmer | Code changes made |
| `04_test_summary.md` | Test Writer | Tests written |
| `05_review_verdict.md` | Code Reviewer | APPROVE or REJECT with feedback |

On review rejection cycles, artifacts are versioned (`_v2`, `_v3`).

### Architecture

Pyre is built on three layers:

**Actions** — Each agent role is a [Jido Action](https://hexdocs.pm/jido_action/Jido.Action.html)
with schema-validated inputs and a `run/2` function. Actions are
flow-agnostic: the same `QAReviewer` action can be used in a feature-building
flow, a PR review flow, or any other pipeline.

```
lib/pyre/actions/
  product_manager.ex    # Requirements from feature description
  designer.ex           # UI/UX design spec
  programmer.ex         # Implementation (versioned on review cycles)
  test_writer.ex        # Test coverage (versioned)
  qa_reviewer.ex        # APPROVE/REJECT verdict (reusable across flows)
```

**Flows** — Pipeline drivers that compose actions into a specific workflow.
Each flow defines its phases and valid transitions:

```
lib/pyre/flows/
  feature_build.ex      # planning -> designing -> implementing ->
                        #   testing -> reviewing -> complete
```

**Plugins** — Shared utilities used by all actions:

```
lib/pyre/plugins/
  persona.ex            # Loads .md persona files, builds LLM messages
  artifact.ex           # Timestamped run directories, versioned files
```

### Customization

#### Persona files

Edit the persona files in `priv/pyre/personas/` to customize agent behavior
for your project. Each file is a Markdown document used as the system prompt.
The installer will not overwrite files that already exist, so your changes
are preserved across updates.

#### Adding a new flow

Create a new module under `lib/pyre/flows/` that reuses existing actions:

```elixir
defmodule Pyre.Flows.PRReview do
  alias Pyre.Actions.QAReviewer

  def run(pr_diff, opts \\ []) do
    context = %{llm: Keyword.get(opts, :llm, Pyre.LLM), streaming: true}

    with {:ok, result} <- QAReviewer.run(%{
           feature_description: "Review this PR",
           requirements: pr_diff,
           design: "",
           implementation: pr_diff,
           tests: "",
           run_dir: "/tmp/review",
           review_cycle: 1
         }, context) do
      {:ok, result.verdict}
    end
  end
end
```

#### Adding a new action

```elixir
defmodule Pyre.Actions.SecurityReviewer do
  use Jido.Action,
    name: "security_reviewer",
    schema: [
      code: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  def run(params, context) do
    model = Pyre.Actions.Helpers.resolve_model(:advanced, context)
    {:ok, sys} = Pyre.Plugins.Persona.system_message(:security_reviewer)
    user = Pyre.Plugins.Persona.user_message("Security review", params.code, params.run_dir, "security.md")

    case Pyre.Actions.Helpers.call_llm(context, model, [sys, user]) do
      {:ok, text} -> {:ok, %{review: text}}
      error -> error
    end
  end
end
```

### Generators

Pyre includes Igniter-based generators that agents use during the pipeline:

- `mix pyre.gen.context` — Generates a context module with CRUD functions
- `mix pyre.gen.live` — Generates LiveView pages with index/show views
- `mix pyre.gen.modal` — Adds a modal component to a LiveView
- `mix pyre.gen.filter` — Adds a filter function to an existing context

### Testing

Actions and flows are testable without LLM calls using the mock:

```elixir
# Test a single action
Process.put(:mock_llm_response, "APPROVE\n\nLooks great!")
{:ok, result} = Pyre.Actions.QAReviewer.run(params, %{llm: Pyre.LLM.Mock, streaming: false})
assert result.verdict == :approve

# Test a full flow with sequenced responses
Process.put(:mock_llm_responses, [
  "Requirements...", "Design...", "Implementation...", "Tests...", "APPROVE\n\nDone."
])
{:ok, state} = Pyre.Flows.FeatureBuild.run("Build a feature", llm: Pyre.LLM.Mock, streaming: false)
assert state.phase == :complete
```
