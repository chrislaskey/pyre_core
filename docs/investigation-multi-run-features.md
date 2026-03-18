# Investigation: Multi-Run Features

## Problem

Today each pipeline execution creates a flat timestamped directory:

```
priv/pyre/runs/
  20260318_010208/
    00_feature.md
    01_requirements.md
    ...
  20260318_143025/
    00_feature.md
    01_requirements.md
    ...
```

These are completely isolated. A run cannot see artifacts from any other run. This works fine for single-shot features, but breaks down for iterative development where:

- A feature takes multiple runs to refine (e.g., run 1 produces requirements + architecture, run 2 implements, run 3 fixes review feedback)
- You want to reference decisions from a prior run ("in the last run, we decided to use GenServer")
- You want to compare artifacts across runs to see how the design evolved
- You want to resume or extend a feature after stopping

## Current Architecture

**Path construction** (hardcoded in both flows):
```elixir
runs_dir = Path.expand("priv/pyre/runs", File.cwd!())
{:ok, run_dir} = Artifact.create_run_dir(runs_dir)
# Result: priv/pyre/runs/20260318_143025/
```

**Artifact flow within a run:**
1. Flow creates timestamped run_dir, writes `00_feature.md`
2. Each action receives `run_dir` + prior artifacts as string params
3. Actions write artifacts to `run_dir` as side effects
4. Artifacts pass through flow state in-memory (no disk reads between stages)
5. Run completes, artifacts persist on disk for human review

**Key constraint:** Actions tell the LLM to write output to a specific path:
```
Write a summary to: /abs/path/priv/pyre/runs/20260318_143025/03_architecture_plan.md
```

## Approaches

### Approach A: Feature Directory with Nested Runs (User's Proposal)

```
priv/pyre/features/
  products-page/
    runs/
      20260318_010208/
        00_feature.md
        01_requirements.md
        ...
      20260318_143025/
        00_feature.md
        05_implementation_summary.md
        ...
    latest -> runs/20260318_143025   (optional symlink)
```

A "feature" is a named container. Each pipeline execution is a "run" within it. Agents can read artifacts from any run in the same feature.

**How it works:**
- User provides a feature name when starting a run (required for new, optional for continuing)
- `Artifact.create_run_dir/1` changes from `create_run_dir(runs_dir)` to `create_run_dir(feature_dir)`
- New function `Artifact.list_runs/1` returns prior runs for a feature
- New function `Artifact.read_prior/3` reads an artifact from a prior run
- Personas get a "Prior Runs" section in the user message with key artifacts from the last run

**Changes needed:**
- `Artifact`: new functions for feature dir management, prior run listing/reading
- Both flows: accept `:feature` option, compute `feature_dir` instead of `runs_dir`
- `Persona.user_message/5`: new optional section for prior run context
- `RunServer`: accept and pass through feature name
- `pyre_web`: feature name input field on new run form
- `mix pyre.run`: `--feature` flag

**Pros:**
- Clean hierarchy — feature is the primary organizing concept
- Easy to find all runs for a feature (just `ls` the feature dir)
- Agents can selectively read prior run artifacts
- Simple mental model: feature > runs > artifacts
- No database or external state — just filesystem

**Cons:**
- Feature naming is a UX question (slug? user-provided? auto-generated?)
- How much prior context to include? Too much overwhelms the LLM context window
- Need to decide which artifacts from prior runs are relevant (all? just the latest? just specific files?)
- Feature directory grows unboundedly over many runs

**Complexity:** Medium

---

### Approach B: Flat Runs with Explicit Lineage

Keep the flat `priv/pyre/runs/` structure but add a `00_meta.json` file that records lineage:

```
priv/pyre/runs/
  20260318_010208/
    00_meta.json          # {"feature": "products-page", "parent_run": null}
    00_feature.md
    01_requirements.md
    ...
  20260318_143025/
    00_meta.json          # {"feature": "products-page", "parent_run": "20260318_010208"}
    00_feature.md
    05_implementation_summary.md
    ...
```

Runs stay flat on disk. The metadata file links them into chains. Reading prior artifacts means: look up parent_run from meta, read from that directory.

**How it works:**
- Each run writes `00_meta.json` with feature name and optional `parent_run` timestamp
- New function `Artifact.parent_run/1` reads meta and returns the parent run_dir
- New function `Artifact.feature_runs/2` scans all runs for matching feature name
- Prior context assembly reads from parent run's artifacts

**Pros:**
- No directory structure changes — just a new file per run
- Lineage is explicit and queryable
- Supports branching (two runs can have the same parent)
- Easy to implement incrementally

**Cons:**
- Finding all runs for a feature requires scanning all run dirs (slow with many runs)
- No visual grouping on filesystem — `ls` shows a flat list
- Lineage can get confusing with many branches
- `00_meta.json` is a different format than the `.md` artifacts (minor inconsistency)

**Complexity:** Low-Medium

---

### Approach C: Feature Directory with Accumulated Context File

```
priv/pyre/features/
  products-page/
    context.md              # Accumulated decisions, evolving document
    runs/
      20260318_010208/
        ...
      20260318_143025/
        ...
```

Like Approach A, but adds a persistent `context.md` file at the feature level that captures key decisions and evolves across runs. Each run reads `context.md` as input and may update it as output.

**How it works:**
- Feature directory has a `context.md` that persists across runs
- First run creates initial context from the feature description
- Subsequent runs receive `context.md` as a "Prior Context" section
- A dedicated "context update" step at the end of each run appends key decisions
- Alternatively, a specific persona (e.g., product_manager) is responsible for maintaining context

**Pros:**
- Solves the "too much prior context" problem — context.md is a curated summary
- Agents don't need to read raw artifacts from prior runs
- context.md becomes the single source of truth for feature-level decisions
- Natural place for human notes too ("actually, let's use Oban instead of GenServer")

**Cons:**
- Who writes/updates context.md? Needs a new action or persona responsibility
- context.md can drift from reality if not maintained
- Adds a new concept (feature-level context) beyond just organizing runs
- More complex than just nesting directories

**Complexity:** Medium-High

---

### Approach D: Feature Directory with Latest Snapshot

```
priv/pyre/features/
  products-page/
    latest/                  # Always contains the most recent versions of all artifacts
      01_requirements.md     # Copied/symlinked from most recent run that produced it
      02_design_spec.md
      03_architecture_plan.md
    runs/
      20260318_010208/
        ...
      20260318_143025/
        ...
```

The `latest/` directory is a materialized view of the most current version of every artifact across all runs. After each run completes, its artifacts are copied (or symlinked) into `latest/`.

**How it works:**
- After each run, `Artifact.update_latest/2` copies new artifacts to `latest/`
- New runs read from `latest/` instead of any specific prior run
- `latest/` always reflects the most up-to-date state of the feature
- Old runs are preserved for history but aren't read by agents

**Pros:**
- Simple mental model — agents always read from `latest/`
- No lineage tracking needed
- No context window bloat (only latest versions, not entire run histories)
- Human can edit `latest/` files directly to steer the next run
- Agents write to `run_dir/` (preserving history), system promotes to `latest/`

**Cons:**
- Promotion logic needs to be smart (don't overwrite requirements with an empty file if a run skipped that stage)
- What if a later run produces worse artifacts? No easy rollback without manual intervention
- Symlinks can be confusing in some editors/tools
- Two "sources of truth" — artifacts in run dirs vs latest/

**Complexity:** Medium

---

### Approach E: Feature Directory, Minimal (Recommended Starting Point)

The simplest version of Approach A — just the directory nesting, no accumulated context or latest snapshot. Prior run access is opt-in via persona instructions.

```
priv/pyre/features/
  products-page/
    20260318_010208/
      00_feature.md
      01_requirements.md
      ...
    20260318_143025/
      00_feature.md
      05_implementation_summary.md
      ...
```

No `runs/` subdirectory, no `latest/`, no `context.md`. Just `features/{name}/{timestamp}/`.

**How it works:**
- Flows accept a `:feature` name (slug)
- `Artifact.create_run_dir/1` becomes `Artifact.create_run_dir(features_dir, feature_name)`
- Returns `priv/pyre/features/{feature_name}/{timestamp}/`
- New `Artifact.prior_runs/1` lists sibling timestamp dirs
- New `Artifact.read_from_run/3` reads a specific artifact from a specific run
- Persona user message includes a "Prior Runs" section listing what exists (filenames only, not content — agents can read what they need via tools)

**Changes needed:**
- `Artifact`: `create_run_dir/2`, `prior_runs/1`, `read_from_run/3`
- Both flows: accept `:feature`, compute feature-scoped path
- `Persona.user_message`: optional prior runs listing
- `RunServer`: accept and pass through feature name
- `pyre_web`: feature name field
- `mix pyre.run`: `--feature` flag

**Pros:**
- Minimal new concepts — just a directory rename with one level of nesting
- Agents already have file tools (Read, Glob) to explore prior runs if needed
- No accumulated state to maintain or sync
- Easy to understand: `ls priv/pyre/features/products-page/` shows all runs
- Leaves room to add context.md or latest/ later without restructuring

**Cons:**
- Agents need to be told about prior runs (persona changes)
- No smart summarization — agent sees raw file listings, must decide what to read
- Feature naming UX still needs solving

**Complexity:** Low

## Comparison Matrix

| Criteria | A: Nested Runs | B: Flat+Lineage | C: Context File | D: Latest Snapshot | E: Minimal |
|----------|---------------|-----------------|-----------------|-------------------|------------|
| Directory change | Yes | No | Yes | Yes | Yes |
| New Artifact code | ~100 LOC | ~80 LOC | ~150 LOC | ~120 LOC | ~60 LOC |
| Cross-run reading | Explicit | Via lineage | Via context.md | Via latest/ | Via tools |
| Context bloat risk | High | High | Low (curated) | Low (latest only) | Low (opt-in) |
| Human editability | Good | Poor | Great | Good | Good |
| Incremental adoption | Yes | Yes | Needs upfront design | Needs promotion logic | Yes |
| Future extensibility | High | Medium | High | Medium | High |

## Recommendation

**Start with Approach E (Feature Directory, Minimal), evolve toward C or D based on usage.**

Rationale:

1. **E is the smallest useful change.** Rename `runs/` to `features/`, add one level of nesting by feature name, done. The filesystem hierarchy alone solves the "find all runs for a feature" problem.

2. **Agents already have the tools they need.** Claude CLI has Bash/Read/Glob. ReqLLM agents have `read_file` and `list_directory`. They can explore prior runs without new Artifact functions — we just need to tell them via persona instructions that prior runs exist and where to find them.

3. **Context.md (Approach C) is the natural next step** once we see what agents actually need from prior runs. It might turn out that a curated summary is essential, or it might turn out that raw artifact access is enough.

4. **Latest snapshot (Approach D) is valuable for the UI** — showing current feature state at a glance. But it's additive and can be layered on later.

5. **No migration needed** (per your note). Clean cut to the new structure.

## Implementation Sketch (Approach E)

### Directory Structure

```
priv/pyre/features/
  {feature_slug}/
    {timestamp_1}/
      00_feature.md
      01_requirements.md
      ...
    {timestamp_2}/
      00_feature.md
      ...
```

### Feature Naming

Options for the slug:
- **User-provided** (simplest): text input on the form, slugified (`My Feature` → `my-feature`)
- **Auto-generated from description**: first few words of feature description, slugified
- **Hash-based**: short hash of the description (less readable but unique)

Recommendation: user-provided with auto-suggest from description. Validation: lowercase alphanumeric + hyphens, max 60 chars.

### Artifact Module Changes

```elixir
# New: create run dir within a feature
def create_feature_run_dir(base_dir, feature_name) do
  feature_dir = Path.join(base_dir, feature_name)
  File.mkdir_p!(feature_dir)
  create_run_dir(feature_dir)
end

# New: list prior runs for a feature (newest first)
def prior_runs(feature_dir) do
  feature_dir
  |> File.ls!()
  |> Enum.filter(&timestamp_dir?/1)
  |> Enum.sort(:desc)
end

# New: list artifacts in a specific run
def list_artifacts(run_dir) do
  run_dir
  |> File.ls!()
  |> Enum.filter(&String.ends_with?(&1, ".md"))
  |> Enum.sort()
end
```

### Flow Changes

```elixir
# Before:
runs_dir = Path.expand("priv/pyre/runs", File.cwd!())
{:ok, run_dir} <- Artifact.create_run_dir(runs_dir)

# After:
features_dir = Path.expand("priv/pyre/features", File.cwd!())
feature_name = Keyword.fetch!(opts, :feature)
{:ok, run_dir} <- Artifact.create_feature_run_dir(features_dir, feature_name)
```

### Prior Run Context in User Message

Add an optional section to `Persona.user_message/5` when prior runs exist:

```markdown
## Prior Runs

This feature has 2 previous runs. You can read artifacts from them if needed:

- `../20260318_010208/` — 01_requirements.md, 02_design_spec.md, 03_architecture_plan.md
- `../20260318_143025/` — 01_requirements.md, 05_implementation_summary.md, 06_review_verdict.md

Use the Read tool to access specific files if prior context would help.
```

This gives the agent awareness without bloating the context window. The agent reads what it needs.

## Open Questions

1. **Is `:feature` required or optional?**
   If required, every run needs a name. If optional, unnamed runs could go to a `_default/` or `_unnamed/` feature directory. Recommendation: required for web UI, optional for CLI (auto-generate from description if omitted).

2. **Should the first run in a feature auto-populate from the last run's artifacts?**
   E.g., if run 1 produced requirements and design, should run 2 automatically receive those as params even if it skips the planning/design stages? This would be a flow-level change.

3. **How do we handle the `--add-dir` flag for Claude CLI?**
   The old Runner passed `--add-dir` to give Claude access to the run_dir. For multi-run features, we might want `--add-dir` for both the current run_dir AND the feature_dir (so Claude can read prior runs).

4. **Pruning/cleanup?**
   Features with many runs will accumulate disk space. Should there be a `mix pyre.clean` task? A configurable retention policy? Manual only?

5. **Feature listing in the web UI?**
   `pyre_web` currently lists runs. With features, the UI should probably show features with their runs nested underneath. This is a separate UI change.

6. **Renaming/archiving features?**
   Just rename/move the directory? Or do we need metadata for this?
