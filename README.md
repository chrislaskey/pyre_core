## Pyre

Multi-agent LLM framework for rapid Phoenix development.

Pyre orchestrates specialized LLM agents — Product Manager, Designer,
Programmer, Test Writer, Code Reviewer, and Shipper — to implement features
in your Phoenix application and open GitHub PRs.

Orchestration layer runs on [Jido](https://jido.run/). Each agent is a reusable
[Jido Action](https://hexdocs.pm/jido_action/Jido.Action.html) with a persona
that guides its output. The pipeline includes a review loop that iterates until
the code reviewer approves.

### Installation

Add `pyre` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pyre, git: "https://github.com/chrislaskey/pyre_core", branch: "main"}
  ]
end
```

**Phoenix 1.8+**: Pyre's transitive dependency chain includes `gettext ~> 0.26`
(via `jido -> sched_ex -> timex`), which conflicts with Phoenix 1.8's
`gettext ~> 1.0`. Add an override in your app's deps to resolve this:

```elixir
{:gettext, "~> 1.0", override: true}
```

Then run the installer to copy persona files and set up the runs directory:

```bash
mix deps.get
mix pyre.install
```

This creates:

- `priv/pyre/personas/` — Editable persona files for each agent
- `priv/pyre/features/.gitkeep` — Directory where pipeline artifacts are stored
- `.gitignore` entries to exclude run output from version control

### Configuration

#### PubSub

If using PyreWeb (the web dashboard), configure your app's PubSub server so
run processes can broadcast real-time updates to LiveViews:

```elixir
# config/config.exs
config :pyre, :pubsub, MyApp.PubSub
```

This should match the PubSub server already started in your application's
supervision tree. Without this, the CLI (`mix pyre.run`) still works but the
web dashboard won't show real-time streaming output.

#### GitHub (Shipper)

To enable the Shipper agent (creates branches and opens GitHub PRs), configure
your repository in `config/runtime.exs`:

```elixir
# config/runtime.exs
if System.get_env("GITHUB_REPO_URL") do
  config :pyre, :github,
    repositories: [
      [
        url: System.get_env("GITHUB_REPO_URL"),
        token: System.get_env("GITHUB_TOKEN"),
        base_branch: System.get_env("GITHUB_BASE_BRANCH", "main")
      ]
    ]
end
```

Set the required environment variables:

```bash
export GITHUB_TOKEN=ghp_...
export GITHUB_REPO_URL=https://github.com/myorg/my-app
```

When using Pyre as a library (e.g. via PyreWeb), the host app sets this config
in its own `runtime.exs`. The Shipper automatically picks up the first
configured repository. To target a specific repo at runtime, pass the
`:github` option:

```elixir
Pyre.Flows.FeatureBuild.run("Build a feature",
  github: %{owner: "acme", repo: "app", token: token, base_branch: "main"}
)
```

#### Allowed Paths (monorepos)

By default, agent file tools (read, write, list directory) are sandboxed to
the working directory. In monorepos where agents need access to sibling apps
or shared libraries, you can allow additional directories.

**Environment variable** (comma-separated):

```bash
export PYRE_ALLOWED_PATHS="/path/to/apps/other,/path/to/libs/shared"
```

**Application config:**

```elixir
# config/runtime.exs
if paths = System.get_env("PYRE_ALLOWED_PATHS") do
  config :pyre,
    allowed_paths:
      paths
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Path.expand/1)
end
```

**Flow option** (programmatic):

```elixir
Pyre.Flows.FeatureBuild.run("Build a feature",
  project_dir: "apps/tools",
  allowed_paths: ["/path/to/apps/other"]
)
```

Relative paths are resolved against the working directory (`--project-dir`),
so `../other` with `--project-dir apps/tools` resolves to `apps/other`. The
working directory itself is always included automatically.

#### LLM API Keys

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

This runs six agents in sequence:

```
Feature Request
  -> Product Manager    (requirements & user stories)
  -> Designer           (UI/UX spec with Tailwind layout)
  -> Programmer         (implementation using Phoenix conventions)
  -> Test Writer        (ExUnit tests)
  -> Code Reviewer      (APPROVE or REJECT)
       -> If REJECT: loop Programmer/TestWriter/Reviewer (up to 3 cycles)
  -> Shipper            (git branch, commit, push, open GitHub PR)
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
| `--feature` | `-n` | Feature name to group related runs |
| `--allowed-paths` | | Comma-separated additional directories agents can access |

#### Artifacts

Each run creates a timestamped directory in `priv/pyre/features/<feature>/` containing:

| File | Agent | Content |
|------|-------|---------|
| `00_feature.md` | — | Original feature request |
| `01_requirements.md` | Product Manager | User stories and acceptance criteria |
| `02_design_spec.md` | Designer | UI/UX specifications |
| `03_implementation_summary.md` | Programmer | Code changes made |
| `04_test_summary.md` | Test Writer | Tests written |
| `05_review_verdict.md` | Code Reviewer | APPROVE or REJECT with feedback |
| `06_shipping_summary.md` | Shipper | Branch name, commit, PR URL |

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
  shipper.ex            # Git branch, commit, push, and GitHub PR
```

**Flows** — Pipeline drivers that compose actions into a specific workflow.
Each flow defines its phases and valid transitions:

```
lib/pyre/flows/
  feature_build.ex      # planning -> designing -> implementing ->
                        #   testing -> reviewing -> shipping -> complete
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

#### Lifecycle hooks

Pyre dispatches lifecycle events (flow start/complete, action start/complete,
LLM call complete) to a configurable callback module. Create a module that
`use Pyre.Config` and override the callbacks you need:

```elixir
defmodule MyApp.PyreConfig do
  use Pyre.Config

  @impl true
  def after_flow_complete(%Pyre.Events.FlowCompleted{} = event) do
    MyApp.Telemetry.emit(:pyre_flow_complete, %{
      flow: event.flow_module,
      elapsed_ms: event.elapsed_ms
    })
    :ok
  end
end
```

Then register it in your config:

```elixir
# config/config.exs
config :pyre, config: MyApp.PyreConfig
```

Any callback not overridden returns `:ok` by default. Exceptions in callbacks
are rescued and logged — they never crash the running flow.

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

