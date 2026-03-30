defmodule Pyre.Flows.Prototype do
  @moduledoc """
  Single-stage prototyping flow.

  Runs a prototype engineer agent that rapidly builds a working
  proof-of-concept:

      prototyping -> complete

  Interactive by default — the agent pauses after its initial response
  for user feedback and iteration.

  ## Usage

      Pyre.Flows.Prototype.run("Build a products listing page")

  ## Options

    * `:llm` -- LLM module (default: `Pyre.LLM`). Use `Pyre.LLM.Mock` for testing.
    * `:fast` -- Override all models to the `:fast` alias. Default `false`.
    * `:dry_run` -- Skip LLM calls, log only. Default `false`.
    * `:streaming` -- Stream LLM output token-by-token. Default `true`.
    * `:verbose` -- Print diagnostic information. Default `false`.
    * `:project_dir` -- Working directory for the agents. Default `"."`.
    * `:allowed_paths` -- Additional directories agents can read/write.
    * `:output_fn` -- Function called with each streaming token. Default `&IO.write/1`.
    * `:log_fn` -- Function called with status/progress messages. Default `&IO.puts/1`.
  """

  alias Pyre.Actions.PrototypeEngineer
  alias Pyre.Plugins.Artifact

  @transitions %{
    prototyping: [:complete],
    complete: []
  }

  @doc """
  Returns the stages that are interactive by default for this flow.

  The Prototype flow is interactive by default — the prototype engineer
  stage pauses for user input after its initial response.
  """
  @spec default_interactive_stages() :: [atom()]
  def default_interactive_stages, do: [:prototyping]

  @doc """
  Runs the prototype pipeline.
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
        session_ids: Keyword.get(opts, :session_ids, %{})
      }

      context.log_fn.("Run directory: #{run_dir}")

      state = %{
        phase: :prototyping,
        feature_description: feature_description,
        run_dir: run_dir,
        working_dir: working_dir,
        attachments: attachments,
        prototype_output: nil
      }

      flow_started_at = System.monotonic_time(:millisecond)

      Pyre.Config.notify(:after_flow_start, %Pyre.Events.FlowStarted{
        flow_module: __MODULE__,
        description: feature_description,
        run_dir: run_dir,
        working_dir: working_dir
      })

      case drive(state, context) do
        {:ok, final_state} ->
          elapsed = System.monotonic_time(:millisecond) - flow_started_at

          Pyre.Config.notify(:after_flow_complete, %Pyre.Events.FlowCompleted{
            flow_module: __MODULE__,
            description: feature_description,
            run_dir: run_dir,
            result: final_state,
            elapsed_ms: elapsed
          })

          {:ok, final_state}

        {:error, reason} = error ->
          elapsed = System.monotonic_time(:millisecond) - flow_started_at

          Pyre.Config.notify(:after_flow_error, %Pyre.Events.FlowError{
            flow_module: __MODULE__,
            description: feature_description,
            run_dir: run_dir,
            error: reason,
            elapsed_ms: elapsed
          })

          error
      end
    end
  end

  defp drive(%{phase: :complete} = state, _context) do
    {:ok, state}
  end

  defp drive(%{phase: :prototyping} = state, context) do
    with {:ok, result} <-
           run_action(PrototypeEngineer, :prototype_engineer, state, context, %{
             feature_description: state.feature_description,
             run_dir: state.run_dir,
             attachments: state.attachments
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:complete)
      |> drive(context)
    end
  end

  # --- Stage orchestration helpers ---

  @stage_to_phase %{
    prototype_engineer: :prototyping
  }

  @stage_fallback_field %{
    prototype_engineer: :prototype_output
  }

  @stage_artifact_info %{
    prototype_engineer: {:prototype_output, "01_prototype_output"}
  }

  @finalize_prompt """
  Based on our conversation, please produce the final version of your output.
  Follow the exact same structure and format as your initial response — keep
  the same sections and headings — but update the content to reflect everything
  we discussed and agreed on.\
  """

  @stage_model_tier %{
    prototype_engineer: :advanced
  }

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

        action_started_at = System.monotonic_time(:millisecond)

        Pyre.Config.notify(:after_action_start, %Pyre.Events.ActionStarted{
          action_module: action_module,
          stage_name: stage_name,
          model: model,
          params: params
        })

        result = action_module.run(params, action_context)
        elapsed = System.monotonic_time(:second) - started_at

        case result do
          {:ok, action_result} ->
            action_elapsed = System.monotonic_time(:millisecond) - action_started_at

            context.log_fn.(
              "--- Completed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )

            Pyre.Config.notify(:after_action_complete, %Pyre.Events.ActionCompleted{
              action_module: action_module,
              stage_name: stage_name,
              result: action_result,
              model: model,
              elapsed_ms: action_elapsed
            })

            maybe_interactive_loop(stage_name, model, action_result, state, context)

          {:error, reason} = error ->
            action_elapsed = System.monotonic_time(:millisecond) - action_started_at

            context.log_fn.(
              "--- Failed: #{stage_name} (#{format_duration(elapsed)}, #{model_label}) ---"
            )

            Pyre.Config.notify(:after_action_error, %Pyre.Events.ActionError{
              action_module: action_module,
              stage_name: stage_name,
              error: reason,
              model: model,
              elapsed_ms: action_elapsed
            })

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
            {:ok, content} = Artifact.read_or_write(state.run_dir, artifact_base, finalized_text)
            {:ok, Map.put(result, field, content)}
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

  defp stage_fallback_text(:prototype_engineer, state) do
    state.feature_description
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
end
