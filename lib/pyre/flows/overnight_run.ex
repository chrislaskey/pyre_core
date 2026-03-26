defmodule Pyre.Flows.OvernightFeature do
  @moduledoc """
  Overnight run multi-agent flow.

  Orchestrates six agent roles through a sequential pipeline:

      planning -> designing -> implementing -> testing -> reviewing -> shipping -> complete

  The reviewing phase can loop back to implementing (up to 3 cycles).
  On approval, the shipping phase creates a git branch, commits, pushes,
  and opens a GitHub PR.

  ## Usage

      Pyre.Flows.OvernightFeature.run("Build a products listing page")

  ## Options

    * `:llm` -- LLM module (default: `Pyre.LLM`). Use `Pyre.LLM.Mock` for testing.
    * `:fast` -- Override all models to the `:fast` alias. Default `false`.
    * `:dry_run` -- Skip LLM calls, log only. Default `false`.
    * `:streaming` -- Stream LLM output token-by-token. Default `true`.
    * `:verbose` -- Print diagnostic information. Default `false`.
    * `:project_dir` -- Working directory for the agents. Default `"."`.
    * `:allowed_paths` -- Additional directories agents can read/write. Useful for
      monorepos where agents need access to sibling apps. Accepts a list of absolute
      paths. Also configurable via `PYRE_ALLOWED_PATHS` env var (comma-separated)
      or `config :pyre, :allowed_paths`.
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
  Runs the complete overnight feature pipeline.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(feature_description, opts \\ []) do
    fast? = Keyword.get(opts, :fast, false)
    streaming? = Keyword.get(opts, :streaming, true)
    verbose? = Keyword.get(opts, :verbose, false)
    project_dir = Keyword.get(opts, :project_dir, ".")
    working_dir = Path.expand(project_dir)
    features_dir = Path.expand("priv/pyre/features", File.cwd!())
    feature = Keyword.get(opts, :feature)

    allowed_paths = Keyword.get(opts, :allowed_paths) || allowed_paths_from_config()

    attachments = Keyword.get(opts, :attachments, [])

    with {:ok, run_dir, feature_dir} <- Artifact.create_run_dir(features_dir, feature),
         :ok <- Artifact.write(run_dir, "00_feature", feature_description),
         :ok <- Artifact.store_attachments(run_dir, attachments) do
      # Give agents access to the feature dir so they can browse prior runs
      allowed_paths = [feature_dir | allowed_paths]

      context = %{
        llm: Keyword.get(opts, :llm, Pyre.LLM.default()),
        streaming: streaming?,
        output_fn: Keyword.get(opts, :output_fn, &IO.write/1),
        log_fn: Keyword.get(opts, :log_fn, &IO.puts/1),
        model_override: if(fast?, do: "anthropic:claude-haiku-4-5"),
        verbose: verbose?,
        dry_run: Keyword.get(opts, :dry_run, false),
        working_dir: working_dir,
        allowed_paths: allowed_paths,
        add_dirs: [feature_dir],
        allowed_commands: Keyword.get(opts, :allowed_commands),
        skip_check_fn: Keyword.get(opts, :skip_check_fn),
        interactive_stage_fn: Keyword.get(opts, :interactive_stage_fn),
        await_user_action_fn: Keyword.get(opts, :await_user_action_fn),
        session_ids: Keyword.get(opts, :session_ids, %{}),
        github: Keyword.get(opts, :github) || github_from_config()
      }

      context.log_fn.("Run directory: #{run_dir}")

      state = %{
        phase: :planning,
        feature_description: feature_description,
        run_dir: run_dir,
        working_dir: working_dir,
        attachments: attachments,
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
             run_dir: state.run_dir,
             attachments: state.attachments
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
             run_dir: state.run_dir,
             attachments: state.attachments
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
      review_cycle: state.review_cycle,
      attachments: state.attachments
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
      review_cycle: state.review_cycle,
      attachments: state.attachments
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
             review_cycle: state.review_cycle,
             attachments: state.attachments
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
             run_dir: state.run_dir,
             attachments: state.attachments
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

  # Maps stage name to {result_field, artifact_base} for the finalize-on-continue call.
  # nil means the stage has a complex return type and finalize is skipped — the
  # conversation still works, the artifact just isn't rewritten.
  @stage_artifact_info %{
    product_manager: {:requirements, "01_requirements"},
    designer: {:design, "02_design_spec"},
    programmer: nil,
    test_writer: nil,
    code_reviewer: nil,
    shipper: nil
  }

  @finalize_prompt """
  Based on our conversation, please produce the final version of your output.
  Follow the exact same structure and format as your initial response — keep
  the same sections and headings — but update the content to reflect everything
  we discussed and agreed on.\
  """

  defp run_action(action_module, stage_name, state, context, params) do
    if stage_skipped?(stage_name, context) do
      context.log_fn.("\n--- Skipping: #{stage_name} (disabled) ---")
      fallback = stage_fallback_text(stage_name, state)
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

        phase = Map.get(@stage_to_phase, stage_name)
        session_id = get_in(context, [:session_ids, phase])
        action_context = if session_id, do: Map.put(context, :session_id, session_id), else: context
        result = action_module.run(params, action_context)
        elapsed = System.monotonic_time(:second) - started_at

        case result do
          {:ok, action_result} ->
            context.log_fn.(
              "--- Completed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )

            maybe_interactive_loop(stage_name, model, action_result, state, context)

          {:error, _} = error ->
            context.log_fn.(
              "--- Failed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )

            error
        end
      end
    end
  end

  defp maybe_interactive_loop(stage_name, model, result, state, context) do
    phase = Map.get(@stage_to_phase, stage_name)

    if interactive_stage?(stage_name, context) do
      session_id = get_in(context, [:session_ids, phase])
      interactive_loop(stage_name, phase, model, session_id, result, state, context, 0)
    else
      {:ok, result}
    end
  end

  defp interactive_loop(stage_name, phase, model, session_id, result, state, context, reply_count) do
    case context.await_user_action_fn.(phase) do
      :continue when reply_count == 0 ->
        {:ok, result}

      :continue ->
        context.log_fn.("\n--- Continuing to next stage. Finalizing artifact for current stage first: #{stage_name} ---")
        finalize_artifact(stage_name, model, session_id, result, state, context)

      {:reply, user_text} ->
        messages = [%{role: :user, content: user_text}]

        opts = [
          resume: session_id,
          streaming: context.streaming,
          output_fn: context.output_fn,
          working_dir: context.working_dir,
          add_dirs: Map.get(context, :add_dirs, [])
        ]

        case context.llm.chat(model, messages, [], opts) do
          {:ok, _response} ->
            interactive_loop(
              stage_name,
              phase,
              model,
              session_id,
              result,
              state,
              context,
              reply_count + 1
            )

          {:error, _} = error ->
            error
        end
    end
  end

  defp finalize_artifact(stage_name, model, session_id, result, state, context) do
    messages = [%{role: :user, content: @finalize_prompt}]

    opts = [
      resume: session_id,
      streaming: context.streaming,
      output_fn: context.output_fn,
      working_dir: context.working_dir,
      add_dirs: Map.get(context, :add_dirs, [])
    ]

    case context.llm.chat(model, messages, [], opts) do
      {:ok, response} ->
        finalized_text = response_to_text(response)

        case Map.get(@stage_artifact_info, stage_name) do
          nil ->
            {:ok, result}

          {field, artifact_base} ->
            :ok = Artifact.write(state.run_dir, artifact_base, finalized_text)
            {:ok, Map.put(result, field, finalized_text)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp response_to_text(%ReqLLM.Response{} = response), do: ReqLLM.Response.text(response) || ""
  defp response_to_text(text) when is_binary(text), do: text

  defp stage_skipped?(stage_name, context) do
    phase = Map.get(@stage_to_phase, stage_name)

    case Map.get(context, :skip_check_fn) do
      nil -> false
      check_fn when is_function(check_fn) -> check_fn.(phase)
    end
  end

  defp interactive_stage?(stage_name, context) do
    phase = Map.get(@stage_to_phase, stage_name)

    case Map.get(context, :interactive_stage_fn) do
      nil -> false
      check_fn when is_function(check_fn) -> check_fn.(phase)
    end
  end

  defp stage_fallback_text(:product_manager, state) do
    state.feature_description
  end

  defp stage_fallback_text(stage_name, _state) do
    Pyre.Plugins.BestPractices.fallback_text(stage_name)
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

  defp allowed_paths_from_config do
    case Application.get_env(:pyre, :allowed_paths) do
      nil -> []
      paths when is_list(paths) -> paths
    end
  end

  defp github_from_config do
    case Application.get_env(:pyre, :github) do
      nil ->
        %{}

      config ->
        repos = Keyword.get(config, :repositories, [])

        case repos do
          [first | _] ->
            url = Keyword.get(first, :url, "")

            case Pyre.GitHub.parse_remote_url(url) do
              {:ok, {owner, repo}} ->
                %{
                  owner: owner,
                  repo: repo,
                  token: Keyword.get(first, :token),
                  base_branch: Keyword.get(first, :base_branch, "main")
                }

              {:error, _} ->
                %{}
            end

          [] ->
            %{}
        end
    end
  end
end
