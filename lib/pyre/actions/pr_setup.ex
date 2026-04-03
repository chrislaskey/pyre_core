defmodule Pyre.Actions.PRSetup do
  @moduledoc """
  Creates a git branch, commits planning artifacts, pushes, and opens a GitHub PR.

  Uses the shipper persona to generate a branch name, PR title, and PR body,
  then executes git operations programmatically. Updates `.gitignore` to allow
  committing `priv/pyre/features/` artifacts.
  """

  use Jido.Action,
    name: "pr_setup",
    description: "Creates branch, commits planning artifacts, pushes, and opens GitHub PR",
    schema: [
      feature_description: [type: :string, required: true],
      architecture_plan: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :shipper
  @artifact_base "04_pr_setup"
  @model_tier :standard

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"03_architecture_plan.md", params.architecture_plan}
        ])

      user_msg =
        Persona.user_message(
          params.feature_description,
          artifacts_content,
          params.run_dir,
          "#{@artifact_base}.md",
          attachments
        )

      case Helpers.call_llm(context, model, [system_msg, user_msg]) do
        {:ok, text} ->
          working_dir = Map.get(context, :working_dir, ".")

          shipping_plan =
            Pyre.Actions.Shipper.parse_shipping_plan(text, params.run_dir, working_dir)

          cond do
            Map.get(context, :dry_run, false) ->
              {:ok, content} = Artifact.read_or_write(params.run_dir, @artifact_base, text)
              {:ok, %{pr_setup: content, branch_name: shipping_plan.branch_name}}

            not git_repo?(working_dir) ->
              log_fn = Map.get(context, :log_fn, &IO.puts/1)
              log_fn.("Not a git repository — skipping git operations")
              {:ok, content} = Artifact.read_or_write(params.run_dir, @artifact_base, text)
              {:ok, %{pr_setup: content, branch_name: shipping_plan.branch_name}}

            not github_configured?(context) ->
              {:error,
               {:github_not_configured,
                "GitHub is not configured. See the Pyre README for details."}}

            true ->
              case execute_pr_setup(shipping_plan, working_dir, context) do
                {:ok, result} ->
                  summary = build_summary(shipping_plan, result)
                  :ok = Artifact.write(params.run_dir, @artifact_base, summary)

                  {:ok,
                   %{
                     pr_setup: summary,
                     branch_name: shipping_plan.branch_name,
                     pr_url: result[:pr_url],
                     pr_number: result[:pr_number]
                   }}

                {:error, _} = error ->
                  error
              end
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp execute_pr_setup(plan, working_dir, context) do
    log_fn = Map.get(context, :log_fn, &IO.puts/1)

    with :ok <- update_gitignore(working_dir, log_fn),
         :ok <- checkout_or_create_branch(plan.branch_name, working_dir, log_fn),
         :ok <- run_git(["add", "-A"], working_dir, log_fn),
         :ok <-
           commit_if_changed(
             "chore: planning artifacts",
             working_dir,
             log_fn
           ),
         :ok <- run_git(["push", "-u", "origin", plan.branch_name], working_dir, log_fn) do
      pr_result = create_pr(plan, context)
      {:ok, pr_result}
    end
  end

  defp checkout_or_create_branch(branch_name, working_dir, log_fn) do
    log_fn.("  git checkout -b #{branch_name}")

    {output, code} =
      System.cmd("git", ["checkout", "-b", branch_name],
        cd: working_dir,
        stderr_to_stdout: true
      )

    cond do
      code == 0 ->
        :ok

      String.contains?(output, "already exists") ->
        log_fn.("  Branch already exists, switching to existing branch")
        run_git(["checkout", branch_name], working_dir, log_fn)

      true ->
        {:error, {:git_error, "git checkout -b #{branch_name}", code, String.trim(output)}}
    end
  end

  defp commit_if_changed(message, working_dir, log_fn) do
    log_fn.("  git commit -m \"#{message}\"")

    {output, code} =
      System.cmd("git", ["commit", "-m", message],
        cd: working_dir,
        stderr_to_stdout: true
      )

    cond do
      code == 0 -> :ok
      String.contains?(output, "nothing to commit") -> :ok
      true -> {:error, {:git_error, "git commit", code, String.trim(output)}}
    end
  end

  defp update_gitignore(working_dir, log_fn) do
    gitignore_path = Path.join(working_dir, ".gitignore")

    case File.read(gitignore_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        # Remove any line that ignores priv/pyre/features (or legacy priv/pyre/runs)
        filtered =
          Enum.reject(lines, fn line ->
            trimmed = String.trim(line)

            trimmed in [
              "priv/pyre/runs",
              "priv/pyre/runs/",
              "priv/pyre/features",
              "priv/pyre/features/"
            ]
          end)

        if filtered != lines do
          new_content = Enum.join(filtered, "\n")
          File.write!(gitignore_path, new_content)
          log_fn.("  Updated .gitignore to allow priv/pyre/features/")
        end

        :ok

      {:error, :enoent} ->
        :ok
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
        %{pr_url: nil, pr_number: nil, pr_error: "github owner/repo not configured"}

      is_nil(token) ->
        log_fn.("Warning: could not create PR (github token not configured)")
        %{pr_url: nil, pr_number: nil, pr_error: "github token not configured"}

      true ->
        case Pyre.GitHub.create_pull_request(
               owner,
               repo,
               %{
                 title: plan.pr_title,
                 body: plan.pr_body,
                 head: plan.branch_name,
                 base: base,
                 draft: true
               },
               token
             ) do
          {:ok, %{url: url, number: number}} ->
            log_fn.("PR created: #{url}")
            %{pr_url: url, pr_number: number}

          {:error, reason} ->
            log_fn.("Warning: could not create PR (#{format_pr_error(reason)})")
            %{pr_url: nil, pr_number: nil, pr_error: format_pr_error(reason)}
        end
    end
  end

  defp format_pr_error(:req_not_available), do: "req dependency not available"
  defp format_pr_error({:validation_error, msg}), do: "GitHub: #{msg}"
  defp format_pr_error({:api_error, status, msg}), do: "GitHub API #{status}: #{msg}"
  defp format_pr_error({:request_failed, reason}), do: "request failed: #{inspect(reason)}"
  defp format_pr_error(other), do: inspect(other)

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

    pr_number_section =
      case result do
        %{pr_number: num} when is_integer(num) -> "- **PR Number**: #{num}"
        _ -> ""
      end

    """
    # PR Setup Summary

    ## Git Operations

    - **Branch**: `#{plan.branch_name}`
    - **Initial Commit**: chore: planning artifacts
    #{pr_section}
    #{pr_number_section}

    ## Push Instructions

    The branch `#{plan.branch_name}` is set up with upstream tracking.
    To push new commits from the working directory:

    ```
    git add -A
    git commit -m "phase N: description"
    git push
    ```

    ## PR Details

    **Title**: #{plan.pr_title}

    #{plan.pr_body}
    """
  end
end
