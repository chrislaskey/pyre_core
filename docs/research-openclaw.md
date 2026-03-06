# OpenClaw: Open-Source Personal AI Agent

> Research notes on the OpenClaw project and its patterns.

## Overview

OpenClaw is an **open-source personal AI assistant** that runs locally on the user's machine. Created by Peter Steinberger. Installed via npm (`npm i -g openclaw`), operates from the CLI with an optional macOS menubar app.

Represents a shift from passive AI tool usage to **active delegation** -- the agent takes instructions and executes multi-step workflows autonomously.

## Key Features

| Feature | Description |
|---------|-------------|
| **Multi-Platform Communication** | WhatsApp, Telegram, Discord, Slack, Signal, iMessage |
| **Full System Access** | File system, shell, browser automation, mouse/keyboard |
| **Persistent Memory** | Learns preferences, 24/7 context retention |
| **Autonomous Background Ops** | Cron jobs, reminders, proactive task initiation |
| **50+ Skills/Plugins** | Spotify, Obsidian, Twitter, GitHub, Gmail, Hue, etc. |
| **Model Flexibility** | Claude, OpenAI, local LLMs |
| **Self-Modification** | Agent can write and modify its own extensions |

## Patterns Relevant to Agent Systems

### Agent Loop
Persistent observe-think-act cycle: receives instructions, plans multi-step workflows, executes tool calls, reports results.

### Tool Orchestration
Rich set of tools (file system, shell, browser, APIs) that the LLM can invoke -- mirrors tool-use patterns in LangChain, CrewAI, Claude's tool-use API.

### Self-Healing / Self-Modification
Can diagnose failures in its own extensions and rewrite them. Can dynamically create new skills based on user requests.

### Context Persistence
Persistent memory carrying learned preferences across sessions.

### Multi-Step Workflow Chaining
Operations chain across services (e.g., check email -> find flight -> check in -> send boarding pass via WhatsApp).

### Privacy-First Local Execution
Runs locally, data stays on user's machine. Relevant to harness engineering decisions around trust boundaries.

## Conceptual Patterns

| Concept | Description |
|---------|-------------|
| **Skills** | Modular, composable capabilities (plugins) |
| **Heartbeat Check-ins** | Proactive status updates enabling trust in autonomy |
| **Cron-Based Autonomy** | Scheduled background tasks without user prompting |
| **Conversational Interface** | Natural language via messaging platforms |
| **Hackability** | Open source, CLI-first, designed for deep customization |

## Relevance to Pyre

OpenClaw represents the **personal assistant** end of the agent spectrum, while Pyre sits at the **development workflow** end. Key patterns that could inform Pyre:

- **Persistent memory across runs**: Pyre currently has artifact files per run but no cross-run learning
- **Self-modification**: Pyre's personas are static; could they evolve based on results?
- **Skill/plugin architecture**: Pyre's generators are a form of skills, but not dynamically extensible
- **Background operation**: Pyre is one-shot; OpenClaw demonstrates the value of persistent agents
