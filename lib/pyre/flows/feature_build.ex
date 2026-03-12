defmodule Pyre.Flows.FeatureBuild do
  @moduledoc """
  Feature-building multi-agent flow.

  Orchestrates six agent roles through a sequential pipeline:

      planning -> designing -> implementing -> testing -> reviewing -> shipping -> complete

  The reviewing phase can loop back to implementing (up to 3 cycles).
  On approval, the shipping phase creates a git branch, commits, pushes,
  and opens a GitHub PR.

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
    * `:log_fn` -- Function called with status/progress messages. Default `&IO.puts/1`.
    * `:github` -- GitHub repo config map with `:owner`, `:repo`, `:token`, and
      optional `:base_branch`. Required for the shipping phase to create PRs.
      Typically set via `config :pyre, :github` in `runtime.exs`.
  """

  alias Pyre.Actions.{ProductManager, Designer, Programmer, TestWriter, QAReviewer, Shipper}
  alias Pyre.Plugins.Artifact

  @max_review_cycles 3

  @transitions %{
    planning: [:designing],
    designing: [:implementing],
    implementing: [:testing],
    testing: [:reviewing],
    reviewing: [:implementing, :shipping, :complete],
    shipping: [:complete],
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
      log_fn: Keyword.get(opts, :log_fn, &IO.puts/1),
      model_override: if(fast?, do: "anthropic:claude-haiku-4-5"),
      verbose: verbose?,
      dry_run: Keyword.get(opts, :dry_run, false),
      working_dir: working_dir,
      allowed_commands: Keyword.get(opts, :allowed_commands),
      skip_check_fn: Keyword.get(opts, :skip_check_fn),
      github: Keyword.get(opts, :github) || github_from_config()
    }

    with {:ok, run_dir} <- Artifact.create_run_dir(runs_dir),
         :ok <- Artifact.write(run_dir, "00_feature", feature_description) do
      context.log_fn.("Run directory: #{run_dir}")

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
        review_cycle: 1,
        shipping_summary: nil
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

  defp drive(%{phase: :shipping} = state, context) do
    with {:ok, result} <-
           run_action(Shipper, :shipper, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             implementation: state.implementation,
             tests: state.tests,
             verdict_text: state.verdict_text,
             run_dir: state.run_dir
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:complete)
      |> drive(context)
    end
  end

  defp handle_verdict(%{verdict: :approve, review_cycle: cycle} = state, context) do
    context.log_fn.("Review: APPROVED (cycle #{cycle})")
    state |> advance_phase(:shipping) |> drive(context)
  end

  defp handle_verdict(%{verdict: nil} = state, context) do
    # Dry-run mode: no verdict was produced, advance to shipping
    state |> advance_phase(:shipping) |> drive(context)
  end

  defp handle_verdict(%{verdict: :reject, review_cycle: cycle} = state, context)
       when cycle >= @max_review_cycles do
    context.log_fn.("Max review cycles (#{@max_review_cycles}) reached. Stopping.")
    state |> advance_phase(:complete) |> drive(context)
  end

  defp handle_verdict(%{verdict: :reject, review_cycle: cycle} = state, context) do
    context.log_fn.("Review: REJECTED (cycle #{cycle}), starting rework...")

    state
    |> Map.put(:review_cycle, cycle + 1)
    |> advance_phase(:implementing)
    |> drive(context)
  end

  @stage_to_phase %{
    product_manager: :planning,
    designer: :designing,
    programmer: :implementing,
    test_writer: :testing,
    code_reviewer: :reviewing,
    shipper: :shipping
  }

  @stage_fallback_field %{
    product_manager: :requirements,
    designer: :design,
    programmer: :implementation,
    test_writer: :tests,
    code_reviewer: {:verdict, :verdict_text},
    shipper: :shipping_summary
  }

  @stage_model_tier %{
    product_manager: :standard,
    designer: :standard,
    programmer: :advanced,
    test_writer: :standard,
    code_reviewer: :advanced,
    shipper: :standard
  }

  defp run_action(action_module, stage_name, _state, context, params) do
    if stage_skipped?(stage_name, context) do
      context.log_fn.("\n--- Skipping: #{stage_name} (disabled) ---")
      fallback = Pyre.Plugins.BestPractices.fallback_text(stage_name)
      {:ok, fallback_result(stage_name, fallback)}
    else
      if context.dry_run do
        context.log_fn.("[dry-run] Would run #{stage_name}")
        {:ok, %{}}
      else
        started_at = System.monotonic_time(:second)
        timestamp = Calendar.strftime(NaiveDateTime.local_now(), "%H:%M:%S")
        tier = Map.get(@stage_model_tier, stage_name, :standard)
        model = Pyre.Actions.Helpers.resolve_model(tier, context)
        model_label = model_short_name(model)
        context.log_fn.("\n--- Stage: #{stage_name} [#{timestamp}] (#{model_label}) ---")

        if context.verbose do
          context.log_fn.("[verbose] action: #{inspect(action_module)}")
          context.log_fn.("[verbose] run_dir: #{params.run_dir}")
        end

        result = action_module.run(params, context)

        elapsed = System.monotonic_time(:second) - started_at

        case result do
          {:ok, _} ->
            context.log_fn.(
              "--- Completed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )

          {:error, _} ->
            context.log_fn.(
              "--- Failed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )
        end

        result
      end
    end
  end

  defp stage_skipped?(stage_name, context) do
    phase = Map.get(@stage_to_phase, stage_name)

    case Map.get(context, :skip_check_fn) do
      nil -> false
      check_fn when is_function(check_fn) -> check_fn.(phase)
    end
  end

  defp fallback_result(:code_reviewer, text) do
    %{verdict: :approve, verdict_text: text}
  end

  defp fallback_result(stage_name, text) do
    field = Map.fetch!(@stage_fallback_field, stage_name)
    %{field => text}
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

  defp model_short_name(model) when is_binary(model) do
    # "anthropic:claude-sonnet-4-20250514" → "claude-sonnet-4"
    model
    |> String.replace(~r/^[^:]+:/, "")
    |> String.replace(~r/-\d{8}$/, "")
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining = rem(seconds, 60)
    "#{minutes}m #{remaining}s"
  end

  defp github_from_config do
    case Application.get_env(:pyre, :github) do
      nil ->
        %{}

      config ->
        repos = Keyword.get(config, :repositories, [])

        case repos do
          [first | _] ->
            %{
              owner: Keyword.get(first, :owner),
              repo: Keyword.get(first, :repo),
              token: Keyword.get(first, :token) || Keyword.get(config, :default_token),
              base_branch: Keyword.get(first, :base_branch, "main")
            }

          [] ->
            case Keyword.get(config, :default_token) do
              nil -> %{}
              token -> %{token: token}
            end
        end
    end
  end
end
