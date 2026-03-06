defmodule Pyre.Flows.FeatureBuild do
  @moduledoc """
  Feature-building multi-agent flow.

  Orchestrates five agent roles through a sequential pipeline:

      planning -> designing -> implementing -> testing -> reviewing -> complete

  The reviewing phase can loop back to implementing (up to 3 cycles).

  ## Usage

      Pyre.Flows.FeatureBuild.run("Build a products listing page")

  ## Options

    * `:llm` -- LLM module (default: `Pyre.LLM`). Use `Pyre.LLM.Mock` for testing.
    * `:fast` -- Override all models to the `:fast` alias. Default `false`.
    * `:dry_run` -- Skip LLM calls, log only. Default `false`.
    * `:streaming` -- Stream LLM output token-by-token. Default `true`.
    * `:verbose` -- Print diagnostic information. Default `false`.
    * `:project_dir` -- Working directory for the agents. Default `"."`.
    * `:output_fn` -- Function called with each streaming token. Default `&IO.write/1`.
  """

  alias Pyre.Actions.{ProductManager, Designer, Programmer, TestWriter, QAReviewer}
  alias Pyre.Plugins.Artifact

  @max_review_cycles 3

  @transitions %{
    planning: [:designing],
    designing: [:implementing],
    implementing: [:testing],
    testing: [:reviewing],
    reviewing: [:implementing, :complete],
    complete: []
  }

  @doc """
  Runs the complete feature-building pipeline.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(feature_description, opts \\ []) do
    fast? = Keyword.get(opts, :fast, false)
    streaming? = Keyword.get(opts, :streaming, true)
    verbose? = Keyword.get(opts, :verbose, false)
    project_dir = Keyword.get(opts, :project_dir, ".")
    working_dir = Path.expand(project_dir)
    runs_dir = Path.expand("priv/pyre/runs", File.cwd!())

    context = %{
      llm: Keyword.get(opts, :llm, Pyre.LLM),
      streaming: streaming?,
      output_fn: Keyword.get(opts, :output_fn, &IO.write/1),
      model_override: if(fast?, do: "anthropic:claude-haiku-4-5"),
      verbose: verbose?,
      dry_run: Keyword.get(opts, :dry_run, false)
    }

    with {:ok, run_dir} <- Artifact.create_run_dir(runs_dir),
         :ok <- Artifact.write(run_dir, "00_feature", feature_description) do
      Mix.shell().info("Run directory: #{run_dir}")

      state = %{
        phase: :planning,
        feature_description: feature_description,
        run_dir: run_dir,
        working_dir: working_dir,
        requirements: nil,
        design: nil,
        implementation: nil,
        tests: nil,
        verdict: nil,
        verdict_text: nil,
        review_cycle: 1
      }

      drive(state, context)
    end
  end

  defp drive(%{phase: :complete} = state, _context) do
    {:ok, state}
  end

  defp drive(%{phase: :planning} = state, context) do
    with {:ok, result} <-
           run_action(ProductManager, :product_manager, state, context, %{
             feature_description: state.feature_description,
             run_dir: state.run_dir
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:designing)
      |> drive(context)
    end
  end

  defp drive(%{phase: :designing} = state, context) do
    with {:ok, result} <-
           run_action(Designer, :designer, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             run_dir: state.run_dir
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:implementing)
      |> drive(context)
    end
  end

  defp drive(%{phase: :implementing} = state, context) do
    params = %{
      feature_description: state.feature_description,
      requirements: state.requirements,
      design: state.design,
      run_dir: state.run_dir,
      review_cycle: state.review_cycle
    }

    params =
      if state.verdict_text,
        do: Map.put(params, :previous_verdict, state.verdict_text),
        else: params

    with {:ok, result} <- run_action(Programmer, :programmer, state, context, params) do
      state
      |> Map.merge(result)
      |> advance_phase(:testing)
      |> drive(context)
    end
  end

  defp drive(%{phase: :testing} = state, context) do
    params = %{
      feature_description: state.feature_description,
      requirements: state.requirements,
      design: state.design,
      implementation: state.implementation,
      run_dir: state.run_dir,
      review_cycle: state.review_cycle
    }

    params =
      if state.verdict_text,
        do: Map.put(params, :previous_verdict, state.verdict_text),
        else: params

    with {:ok, result} <- run_action(TestWriter, :test_writer, state, context, params) do
      state
      |> Map.merge(result)
      |> advance_phase(:reviewing)
      |> drive(context)
    end
  end

  defp drive(%{phase: :reviewing} = state, context) do
    with {:ok, result} <-
           run_action(QAReviewer, :code_reviewer, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             implementation: state.implementation,
             tests: state.tests,
             run_dir: state.run_dir,
             review_cycle: state.review_cycle
           }) do
      state = Map.merge(state, result)
      handle_verdict(state, context)
    end
  end

  defp handle_verdict(%{verdict: :approve, review_cycle: cycle} = state, context) do
    Mix.shell().info("Review: APPROVED (cycle #{cycle})")
    state |> advance_phase(:complete) |> drive(context)
  end

  defp handle_verdict(%{verdict: nil} = state, context) do
    # Dry-run mode: no verdict was produced, treat as complete
    state |> advance_phase(:complete) |> drive(context)
  end

  defp handle_verdict(%{verdict: :reject, review_cycle: cycle} = state, context)
       when cycle >= @max_review_cycles do
    Mix.shell().info("Max review cycles (#{@max_review_cycles}) reached. Stopping.")
    state |> advance_phase(:complete) |> drive(context)
  end

  defp handle_verdict(%{verdict: :reject, review_cycle: cycle} = state, context) do
    Mix.shell().info("Review: REJECTED (cycle #{cycle}), starting rework...")

    state
    |> Map.put(:review_cycle, cycle + 1)
    |> advance_phase(:implementing)
    |> drive(context)
  end

  defp run_action(action_module, stage_name, _state, context, params) do
    if context.dry_run do
      Mix.shell().info("[dry-run] Would run #{stage_name}")
      {:ok, %{}}
    else
      started_at = System.monotonic_time(:second)
      timestamp = Calendar.strftime(NaiveDateTime.local_now(), "%H:%M:%S")
      Mix.shell().info("\n--- Stage: #{stage_name} [#{timestamp}] ---")

      if context.verbose do
        Mix.shell().info("[verbose] action: #{inspect(action_module)}")
        Mix.shell().info("[verbose] run_dir: #{params.run_dir}")
      end

      result = action_module.run(params, context)

      elapsed = System.monotonic_time(:second) - started_at

      case result do
        {:ok, _} ->
          Mix.shell().info("--- Completed: #{stage_name} (#{format_duration(elapsed)}) ---")

        {:error, _} ->
          Mix.shell().info("--- Failed: #{stage_name} (#{format_duration(elapsed)}) ---")
      end

      result
    end
  end

  defp advance_phase(state, next_phase) do
    current = state.phase
    valid_next = Map.get(@transitions, current, [])

    if next_phase in valid_next do
      %{state | phase: next_phase}
    else
      raise "Invalid phase transition: #{current} -> #{next_phase}"
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining = rem(seconds, 60)
    "#{minutes}m #{remaining}s"
  end
end
