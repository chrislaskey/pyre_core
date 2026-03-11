defmodule Pyre.Actions.Shipper do
  @moduledoc """
  Creates a git branch, commits changes, pushes, and opens a GitHub PR.

  Uses a single LLM call to generate creative content (branch name, commit
  message, PR title, PR body) from all prior artifacts, then executes git
  commands programmatically.
  """

  use Jido.Action,
    name: "shipper",
    description: "Creates a feature branch, commits, pushes, and opens a GitHub PR",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      implementation: [type: :string, required: true],
      tests: [type: :string, required: true],
      verdict_text: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :shipper
  @artifact_base "06_shipping_summary"
  @model_tier :standard

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      artifacts_content =
        Helpers.assemble_artifacts([
          {"01_requirements.md", params.requirements},
          {"02_design_spec.md", params.design},
          {"03_implementation_summary.md", params.implementation},
          {"04_test_summary.md", params.tests},
          {"05_review_verdict.md", params.verdict_text}
        ])

      user_msg =
        Persona.user_message(
          params.feature_description,
          artifacts_content,
          params.run_dir,
          "#{@artifact_base}.md"
        )

      case Helpers.call_llm(context, model, [system_msg, user_msg]) do
        {:ok, text} ->
          shipping_plan = parse_shipping_plan(text)
          working_dir = Map.get(context, :working_dir, ".")
          log_fn = Map.get(context, :log_fn, &IO.puts/1)

          cond do
            Map.get(context, :dry_run, false) ->
              :ok = Artifact.write(params.run_dir, @artifact_base, text)
              {:ok, %{shipping_summary: text}}

            not git_repo?(working_dir) ->
              log_fn.("Not a git repository — skipping git operations")
              :ok = Artifact.write(params.run_dir, @artifact_base, text)
              {:ok, %{shipping_summary: text}}

            true ->
              case execute_shipping(shipping_plan, working_dir, log_fn) do
                {:ok, result} ->
                  summary = build_summary(shipping_plan, result)
                  :ok = Artifact.write(params.run_dir, @artifact_base, summary)
                  {:ok, %{shipping_summary: summary}}

                {:error, _} = error ->
                  error
              end
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @doc false
  def parse_shipping_plan(text) do
    sections = split_sections(text)

    %{
      branch_name: sections |> Map.get("Branch Name", "feature/pyre-changes") |> String.trim(),
      commit_message: sections |> Map.get("Commit Message", "feat: implement feature") |> strip_code_fences() |> String.trim(),
      pr_title: sections |> Map.get("PR Title", "Implement feature") |> String.trim(),
      pr_body: sections |> Map.get("PR Body", "") |> String.trim()
    }
  end

  defp split_sections(text) do
    text
    |> String.split(~r/^## /m)
    |> Enum.drop(1)
    |> Enum.map(fn section ->
      case String.split(section, "\n", parts: 2) do
        [heading, body] -> {String.trim(heading), String.trim(body)}
        [heading] -> {String.trim(heading), ""}
      end
    end)
    |> Map.new()
  end

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/^```\w*\n/m, "")
    |> String.replace(~r/\n```$/m, "")
  end

  defp git_repo?(working_dir) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: working_dir,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  defp execute_shipping(plan, working_dir, log_fn) do
    with :ok <- run_git(["checkout", "-b", plan.branch_name], working_dir, log_fn),
         :ok <- run_git(["add", "-A"], working_dir, log_fn),
         :ok <- run_git(["commit", "-m", plan.commit_message], working_dir, log_fn),
         :ok <- run_git(["push", "-u", "origin", plan.branch_name], working_dir, log_fn) do
      pr_result = create_pr(plan, working_dir, log_fn)
      {:ok, pr_result}
    end
  end

  defp create_pr(plan, working_dir, log_fn) do
    {output, code} =
      System.cmd("gh", ["pr", "create", "--title", plan.pr_title, "--body", plan.pr_body],
        cd: working_dir,
        stderr_to_stdout: true
      )

    if code == 0 do
      pr_url = output |> String.trim()
      log_fn.("PR created: #{pr_url}")
      %{pr_url: pr_url}
    else
      log_fn.("Warning: could not create PR (gh CLI returned #{code}): #{String.trim(output)}")
      %{pr_url: nil, pr_error: String.trim(output)}
    end
  end

  defp run_git(args, working_dir, log_fn) do
    log_fn.("  git #{Enum.join(args, " ")}")

    {output, code} =
      System.cmd("git", args,
        cd: working_dir,
        stderr_to_stdout: true
      )

    if code == 0 do
      :ok
    else
      {:error, {:git_error, "git #{Enum.join(args, " ")}", code, String.trim(output)}}
    end
  end

  defp build_summary(plan, result) do
    pr_section =
      case result do
        %{pr_url: url} when is_binary(url) -> "- **PR URL**: #{url}"
        %{pr_error: error} -> "- **PR**: Could not create (#{error})"
        _ -> "- **PR**: Not created"
      end

    """
    # Shipping Summary

    ## Git Operations

    - **Branch**: `#{plan.branch_name}`
    - **Commit**: #{String.split(plan.commit_message, "\n") |> List.first()}
    #{pr_section}

    ## PR Details

    **Title**: #{plan.pr_title}

    #{plan.pr_body}
    """
  end
end
