defmodule Pyre.Flows.IterativeBuild do
  @moduledoc """
  Iterative multi-agent build flow.

  Orchestrates six agent roles through a sequential pipeline:

      planning -> designing -> architecting -> branch_setup -> engineering -> reviewing -> complete

  The Software Architect breaks the feature into small phases with acceptance
  criteria. The Branch Setup creates a git branch and GitHub PR. The Software
  Engineer then implements all phases in a single agentic session, committing
  per phase. The PR Reviewer posts a GitHub review at the end.

  ## Usage

      Pyre.Flows.IterativeBuild.run("Build a products listing page")

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
    * `:github` -- GitHub repo config map with `:owner`, `:repo`, `:token`, and
      optional `:base_branch`. Required for branch setup and PR review.
  """

  alias Pyre.Actions.{
    ProductManager,
    Designer,
    SoftwareArchitect,
    BranchSetup,
    SoftwareEngineer,
    PRReviewer
  }

  alias Pyre.Plugins.Artifact

  @transitions %{
    planning: [:designing],
    designing: [:architecting],
    architecting: [:branch_setup],
    branch_setup: [:engineering],
    engineering: [:reviewing],
    reviewing: [:complete],
    complete: []
  }

  @doc """
  Runs the iterative build pipeline.
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
        architecture_plan: nil,
        branch_setup: nil,
        branch_name: nil,
        pr_url: nil,
        pr_number: nil,
        implementation_summary: nil,
        review: nil,
        verdict: nil
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
      |> advance_phase(:architecting)
      |> drive(context)
    end
  end

  defp drive(%{phase: :architecting} = state, context) do
    with {:ok, result} <-
           run_action(SoftwareArchitect, :software_architect, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             run_dir: state.run_dir,
             attachments: state.attachments
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:branch_setup)
      |> drive(context)
    end
  end

  defp drive(%{phase: :branch_setup} = state, context) do
    with {:ok, result} <-
           run_action(BranchSetup, :branch_setup, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             architecture_plan: state.architecture_plan,
             run_dir: state.run_dir,
             attachments: state.attachments
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:engineering)
      |> drive(context)
    end
  end

  defp drive(%{phase: :engineering} = state, context) do
    with {:ok, result} <-
           run_action(SoftwareEngineer, :software_engineer, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             architecture_plan: state.architecture_plan,
             branch_setup: state.branch_setup,
             run_dir: state.run_dir,
             attachments: state.attachments
           }) do
      state
      |> Map.merge(result)
      |> advance_phase(:reviewing)
      |> drive(context)
    end
  end

  defp drive(%{phase: :reviewing} = state, context) do
    with {:ok, result} <-
           run_action(PRReviewer, :pr_reviewer, state, context, %{
             feature_description: state.feature_description,
             requirements: state.requirements,
             design: state.design,
             architecture_plan: state.architecture_plan,
             implementation_summary: state.implementation_summary,
             run_dir: state.run_dir,
             pr_number: state.pr_number,
             attachments: state.attachments
           }) do
      verdict = Map.get(result, :verdict)
      event = if verdict == :approve, do: "APPROVED", else: "REQUEST_CHANGES"
      context.log_fn.("Review: #{event}")

      state
      |> Map.merge(result)
      |> advance_phase(:complete)
      |> drive(context)
    end
  end

  # --- Stage orchestration helpers ---

  @stage_to_phase %{
    product_manager: :planning,
    designer: :designing,
    software_architect: :architecting,
    branch_setup: :branch_setup,
    software_engineer: :engineering,
    pr_reviewer: :reviewing
  }

  @stage_fallback_field %{
    product_manager: :requirements,
    designer: :design,
    software_architect: :architecture_plan,
    branch_setup: :branch_setup,
    software_engineer: :implementation_summary,
    pr_reviewer: {:verdict, :review}
  }

  @stage_model_tier %{
    product_manager: :standard,
    designer: :standard,
    software_architect: :advanced,
    branch_setup: :standard,
    software_engineer: :standard,
    pr_reviewer: :advanced
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

  defp stage_fallback_text(:product_manager, state) do
    state.feature_description
  end

  defp stage_fallback_text(stage_name, _state) do
    Pyre.Plugins.BestPractices.fallback_text(stage_name)
  end

  defp fallback_result(:pr_reviewer, text) do
    %{verdict: :approve, review: text}
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
