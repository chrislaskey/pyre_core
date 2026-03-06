# Jido: Pure Functional Agent Framework for Elixir

> Research notes for evaluating Jido as a potential enhancement to Pyre.

## Overview

Jido (Japanese for "automatic/self-moving") is a **pure functional agent framework for Elixir** built on OTP. Version 2.0.0, Apache 2.0 licensed, requires Elixir 1.17+ / OTP 26+.

It is not a "better GenServer" -- it codifies patterns teams repeatedly reinvent when building agent systems with raw OTP.

## Core Mental Model

Follows an **Elm/Redux-inspired architecture**:

```
Signal -> Action -> cmd/2 -> {agent, directives} -> runtime executes directives
```

Four foundational tenets:

1. **Agents are immutable** -- `cmd/2` never mutates state; returns a fresh agent instance
2. **State changes and effects are separate** -- directives describe effects without modifying the agent
3. **Runtime executes directives** -- agents never perform side effects themselves
4. **Pure determinism** -- identical inputs always produce identical outputs

## Architecture: Three Layers of Change

| Layer | Role | Scope |
|-------|------|-------|
| **Actions** | Transform state; may trigger side effects | Executed by `cmd/2`, update `agent.state` |
| **State Operations** | Internal transitions (SetState, ReplaceState, etc.) | Applied by strategy layer; never reach runtime |
| **Directives** | External effect descriptions (Emit, Spawn, Schedule, etc.) | Interpreted by AgentServer; never modify state |

## Agent Definition

Agents are immutable structs with schema-validated state:

```elixir
defmodule CounterAgent do
  use Jido.Agent,
    name: "counter",
    description: "A simple counter agent",
    schema: [
      count: [type: :integer, default: 0],
      status: [type: :atom, default: :idle]
    ],
    signal_routes: [
      {"increment", MyApp.Actions.Increment}
    ]
end
```

The fundamental operation is `cmd/2`:

```elixir
{agent, directives} = MyAgent.cmd(agent, action)
```

Returns an updated agent + a list of directives describing external effects.

## Actions

Reusable, schema-validated command modules:

```elixir
defmodule MyApp.Actions.Increment do
  use Jido.Action,
    name: "increment",
    schema: [amount: [type: :integer, default: 1]]

  def run(params, context) do
    current = context.state[:count] || 0
    {:ok, %{count: current + params.amount}}
  end
end
```

## Directives System

Bare structs describing external effects. Built-in types:

- **Emit** -- dispatch signals via adapters (PID, PubSub, bus, HTTP)
- **Spawn / SpawnAgent** -- launch child processes or agents
- **StopChild** -- gracefully stop child agents
- **Schedule** -- delay message delivery
- **Cron / CronCancel** -- recurring scheduled execution
- **Stop** -- terminate the agent process

Custom directives are trivially defined:

```elixir
defmodule MyApp.Directive.CallLLM do
  defstruct [:model, :prompt, :tag]
end
```

## Signals (CloudEvents v1.0.2)

Standardized message envelopes via the `jido_signal` package:

- **Signal Bus**: In-memory pub/sub with persistent subscriptions, retry, dead letter queues, history, and replay
- **Router**: Trie-based pattern matching with wildcards
- **Dispatch**: Multiple adapters (PID, Phoenix.PubSub, HTTP webhooks)
- **Causality Tracking**: Complete signal relationship graphs
- **Instance Isolation**: Multi-tenant support through isolated registries

## Execution Strategies

- **Direct Strategy**: Simple action-to-state transformation
- **FSM Strategy**: Finite state machine with state transitions
- **Custom Strategies**: Extensible protocol for domain-specific patterns

```elixir
defmodule MyAgent do
  use Jido.Agent,
    strategy: {Jido.Agent.Strategy.FSM,
      initial_state: "idle",
      transitions: %{
        "idle" => ["processing"],
        "processing" => ["idle", "completed", "failed"]
      }
    }
end
```

## Runtime: AgentServer

GenServer-based wrapper for production deployment:

```elixir
{:ok, pid} = MyApp.Jido.start_agent(CounterAgent, id: "counter-1")

{:ok, agent} = Jido.AgentServer.call(
  pid,
  Jido.Signal.new!("increment", %{amount: 10}, source: "/user")
)
```

## Ecosystem

| Package | Purpose |
|---------|---------|
| `jido` | Core framework |
| `jido_signal` | CloudEvents messaging, pub/sub, routing |
| `jido_ai` | LLM integration (Claude, OpenAI, Gemini, etc.) |
| `jido_action` | Composable validated actions with AI tool integration |
| `req_llm` | HTTP client for LLM APIs |
| `jido_workbench` | Phoenix LiveView docs/examples |

## What People Are Building (48 examples)

**Core Patterns**: Counter agents, cart calculators, budget guardrails, capacity trackers

**Workflow Orchestration**: Payment retry orchestrators, order approval chains, workflow coordinators, dead letter reprocessors, ticket triage swarm coordinators

**Data Processing**: CSV import validators, changelog linters, dependency license classifiers, text-to-SQL analytics

**AI/Research**: Deep research agents, adaptive researchers, document-grounded Q&A, coding assistants

**Specialized**: Browser agents, feature flag auditing, incident triage, meeting prep

## What Makes Jido Different

| Raw OTP / Ad-hoc | Jido |
|---|---|
| Ad-hoc message shapes | CloudEvents-based standardized signals |
| Business logic in GenServer callbacks | Reusable, validated Action modules |
| Implicit, scattered side effects | Typed, inspectable Directives |
| Mutable state in process | Immutable agent structs with pure `cmd/2` |
| Hard to test (requires spawning) | Directly testable pure functions |
| Global singletons | Instance-scoped multi-tenant architecture |

## Installation

```elixir
# mix.exs
def deps do
  [{:jido, "~> 2.0"}]
end
```

Or via Igniter: `mix igniter.install jido`
