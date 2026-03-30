defmodule Pyre.Actions.Shipper do
  @moduledoc """
  Creates a git branch, commits changes, pushes, and opens a GitHub PR.

  Uses a single LLM call to generate creative content (branch name, commit
  message, PR title, PR body) from all prior artifacts, then executes git
  commands programmatically.

  ## GitHub Configuration

  Requires `context.github` with `:owner`, `:repo`, and `:token` keys.
  Optional `:base_branch` defaults to `"main"`.

  These are typically set via `config :pyre, :github` in `runtime.exs` and
  threaded through the flow context.
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
      attachments = Map.get(params, :attachments, [])

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
          "#{@artifact_base}.md",
          attachments
        )

      messages = [system_msg, user_msg]

      llm_opts =
        if manages_own_tools?(context) do
          []
        else
          working_dir = Map.get(context, :working_dir, ".")
          tool_opts = Helpers.tool_opts(context)
          tools = Pyre.Tools.for_role(:shipper, working_dir, tool_opts)
          [tools: tools]
        end

      case Helpers.call_llm(context, model, messages, llm_opts) do
        {:ok, text} ->
          working_dir = Map.get(context, :working_dir, ".")
          shipping_plan = parse_shipping_plan(text, params.run_dir, working_dir)

          cond do
            Map.get(context, :dry_run, false) ->
              {:ok, content} = Artifact.read_or_write(params.run_dir, @artifact_base, text)
              {:ok, %{shipping_summary: content}}

            not git_repo?(working_dir) ->
              log_fn = Map.get(context, :log_fn, &IO.puts/1)
              log_fn.("Not a git repository — skipping git operations")
              {:ok, content} = Artifact.read_or_write(params.run_dir, @artifact_base, text)
              {:ok, %{shipping_summary: content}}

            not github_configured?(context) ->
              {:error,
               {:github_not_configured,
                "GitHub is not configured. See the Pyre README for details."}}

            true ->
              case execute_shipping(shipping_plan, working_dir, context) do
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
  def parse_shipping_plan(text, run_dir \\ nil, working_dir \\ nil) do
    sections = split_sections(text)
    feature = default_branch_name(working_dir) || feature_slug(run_dir)

    %{
      branch_name:
        sections |> Map.get("Branch Name", feature) |> String.trim(),
      commit_message:
        sections
        |> Map.get("Commit Message", "feat: implement #{feature}")
        |> strip_code_fences()
        |> String.trim(),
      pr_title: sections |> Map.get("PR Title", "Implement #{feature}") |> String.trim(),
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

  defp github_configured?(context) do
    github = Map.get(context, :github, %{})
    is_binary(github[:owner]) and is_binary(github[:repo]) and is_binary(github[:token])
  end

  defp execute_shipping(plan, working_dir, context) do
    log_fn = Map.get(context, :log_fn, &IO.puts/1)

    with :ok <- run_git(["checkout", "-b", plan.branch_name], working_dir, log_fn),
         :ok <- run_git(["add", "-A"], working_dir, log_fn),
         :ok <- run_git(["commit", "-m", plan.commit_message], working_dir, log_fn),
         :ok <- run_git(["push", "-u", "origin", plan.branch_name], working_dir, log_fn) do
      pr_result = create_pr(plan, context)
      {:ok, pr_result}
    end
  end

  defp create_pr(plan, context) do
    log_fn = Map.get(context, :log_fn, &IO.puts/1)
    github = Map.get(context, :github, %{})

    owner = github[:owner]
    repo = github[:repo]
    token = github[:token]
    base = github[:base_branch] || "main"

    cond do
      is_nil(owner) or is_nil(repo) ->
        log_fn.("Warning: could not create PR (github owner/repo not configured)")
        %{pr_url: nil, pr_error: "github owner/repo not configured"}

      is_nil(token) ->
        log_fn.("Warning: could not create PR (github token not configured)")
        %{pr_url: nil, pr_error: "github token not configured"}

      true ->
        case Pyre.GitHub.create_pull_request(
               owner,
               repo,
               %{
                 title: plan.pr_title,
                 body: plan.pr_body,
                 head: plan.branch_name,
                 base: base
               },
               token
             ) do
          {:ok, %{url: url}} ->
            log_fn.("PR created: #{url}")
            %{pr_url: url}

          {:error, reason} ->
            log_fn.("Warning: could not create PR (#{format_pr_error(reason)})")
            %{pr_url: nil, pr_error: format_pr_error(reason)}
        end
    end
  end

  defp format_pr_error(:req_not_available), do: "req dependency not available"
  defp format_pr_error({:validation_error, msg}), do: "GitHub: #{msg}"
  defp format_pr_error({:api_error, status, msg}), do: "GitHub API #{status}: #{msg}"
  defp format_pr_error({:request_failed, reason}), do: "request failed: #{inspect(reason)}"
  defp format_pr_error(other), do: inspect(other)

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

  defp default_branch_name(nil), do: nil

  defp default_branch_name(working_dir) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: working_dir,
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        branch = String.trim(branch)
        if branch in ["main", "master"], do: nil, else: branch

      _ ->
        nil
    end
  end

  defp feature_slug(nil), do: "pyre-changes"

  defp feature_slug(run_dir) do
    # run_dir is {base}/{feature_slug}/{timestamp}
    run_dir |> Path.dirname() |> Path.basename()
  end

  defp manages_own_tools?(context) do
    llm = Map.get(context, :llm, Pyre.LLM.default())
    function_exported?(llm, :manages_tool_loop?, 0) and llm.manages_tool_loop?()
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
