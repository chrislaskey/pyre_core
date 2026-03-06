# Changelog

## v0.2.0 — Use Jido for orchestration

Replaced the original orchestrator with a modular architecture built on [Jido](https://jido.run/).

### Breaking Changes

- **LLM provider**: No longer shells out to the `claude` CLI. Uses the Anthropic API (or any provider supported by ReqLLM) directly. Requires an `ANTHROPIC_API_KEY` environment variable.
- **Return values**: `Pyre.Flows.FeatureBuild.run/2` returns `{:ok, state}` instead of `:ok`.
- **Removed modules**: `Pyre.Agents.Orchestrator`, `Pyre.Agents.Runner`, `Pyre.Agents.Persona`, `Pyre.Agents.Artifact` have been replaced.

### Added

- **Jido Actions** (`Pyre.Actions.*`) — Schema-validated, reusable action modules for each agent role (ProductManager, Designer, Programmer, TestWriter, QAReviewer). Actions are flow-agnostic and can be composed into different pipelines.
- **Flow driver** (`Pyre.Flows.FeatureBuild`) — Pipeline orchestration with explicit phase tracking and validated transitions. Replaces the hardcoded orchestrator.
- **LLM abstraction** (`Pyre.LLM`) — Behaviour-based LLM interface wrapping ReqLLM. Supports token-by-token streaming and multiple providers (Anthropic, OpenAI, etc.).
- **Mock LLM** (`Pyre.LLM.Mock`) — Test helper with sequenced responses via process dictionary.
- **Plugins** (`Pyre.Plugins.Persona`, `Pyre.Plugins.Artifact`) — Extracted utilities for persona loading and artifact management.
- **Config files** — `config/config.exs` for model aliases, `config/runtime.exs` for API keys.
- **`--no-stream` flag** — Disable streaming output.
- **`--verbose` flag** — Print diagnostic information during pipeline execution.

### Changed

- Streaming is now token-by-token (SSE) instead of line-by-line (CLI stdout).
- Inter-stage data flows as structured maps in memory. Markdown artifacts are still written to disk as a side effect for human inspection.
- Model selection uses semantic aliases (`fast`, `standard`, `advanced`) mapped to provider-specific model IDs in config.

### Removed

- `claude` CLI dependency — LLM calls go through the API directly.
- `Pyre.Agents.*` namespace — Replaced by `Pyre.Actions.*`, `Pyre.Flows.*`, and `Pyre.Plugins.*`.

## v0.1.0 — Initial Release

Multi-agent pipeline orchestrating five Claude agents via the Claude Code CLI. Hardcoded stage pipeline with review loop, file-based artifact passing, Igniter-based code generators.
