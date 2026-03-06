# Changelog

## v0.3.0 — Tool use (agents can modify files)

Agents now use LLM tool calling to read, write, and execute commands in the target project. The Programmer, TestWriter, and QAReviewer actions have real tools — they actually create files, run generators, and verify compilation instead of just describing what they would do.

### Added

- **Tool definitions** (`Pyre.Tools`) — Four tools (`read_file`, `write_file`, `list_directory`, `run_command`) with path sandboxing and command allowlisting.
- **Agentic loop** (`Pyre.Tools.AgenticLoop`) — Multi-turn tool-use conversation loop. Calls the LLM, executes tool calls, feeds results back, and repeats until the LLM produces a final answer (max 25 iterations).
- **`Pyre.LLM.chat/4`** — New callback that returns the full `ReqLLM.Response` struct (tool_calls, finish_reason, context) for tool-use workflows. Existing `generate/3` and `stream/3` are unchanged.

### Changed

- **Programmer, TestWriter, QAReviewer** now receive tools and can modify the project directly via the API's function calling feature.
- **ProductManager and Designer** are unchanged — they produce text artifacts only.
- **Persona files** updated to describe available tools instead of XML-style tags.
- `Pyre.LLM.Mock.chat/4` returns a mock `ReqLLM.Response` with `finish_reason: :stop`, so existing tests work without tool execution.

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
