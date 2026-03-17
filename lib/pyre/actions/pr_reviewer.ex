defmodule Pyre.Actions.PRReviewer do
  @moduledoc """
  Reviews the complete PR and posts a GitHub comment.

  Reuses the code_reviewer persona to evaluate all implementation phases,
  then posts a comment on the GitHub PR. If the verdict is APPROVE, the
  draft PR is also marked as ready for review.
  """

  use Jido.Action,
    name: "pr_reviewer",
    description: "Reviews complete PR and posts GitHub review comment",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      architecture_plan: [type: :string, required: true],
      implementation_summary: [type: :string, required: true],
      run_dir: [type: :string, required: true],
      pr_number: [type: :integer, doc: "GitHub PR number for posting review"]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :code_reviewer
  @artifact_base "07_pr_review"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"01_requirements.md", params.requirements},
          {"02_design_spec.md", params.design},
          {"03_architecture_plan.md", params.architecture_plan},
          {"06_implementation_summary.md", params.implementation_summary}
        ])

      user_msg =
        Persona.user_message(
          params.feature_description,
          artifacts_content,
          params.run_dir,
          "#{@artifact_base}.md",
          attachments
        )

      working_dir = Map.get(context, :working_dir, ".")
      tool_opts = Helpers.tool_opts(context)
      tools = Pyre.Tools.for_role(:qa_reviewer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, @artifact_base, text)
          verdict = Pyre.Actions.QAReviewer.parse_verdict(text)

          commit_review_artifact(working_dir, context)
          maybe_post_review(verdict, text, params, context)

          {:ok, %{review: text, verdict: verdict}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp commit_review_artifact(working_dir, context) do
    log_fn = Map.get(context, :log_fn, &IO.puts/1)

    with true <- git_repo?(working_dir),
         {_, 0} <- System.cmd("git", ["add", "-A"], cd: working_dir, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", "chore: add pyre review artifacts"],
             cd: working_dir,
             stderr_to_stdout: true
           ),
         {_, 0} <- System.cmd("git", ["push"], cd: working_dir, stderr_to_stdout: true) do
      log_fn.("Committed and pushed review artifacts")
    else
      false -> :ok
      {output, code} -> log_fn.("Warning: could not commit review artifacts (exit #{code}: #{String.trim(output)})")
    end
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

  defp maybe_post_review(verdict, text, params, context) do
    github = Map.get(context, :github, %{})
    pr_number = Map.get(params, :pr_number)
    log_fn = Map.get(context, :log_fn, &IO.puts/1)

    if pr_number && github[:owner] && github[:repo] && github[:token] do
      owner = github[:owner]
      repo = github[:repo]
      token = github[:token]

      # Post as a PR comment (not a formal review)
      case Pyre.GitHub.create_comment(owner, repo, pr_number, text, token) do
        {:ok, _} -> log_fn.("Posted PR comment")
        {:error, reason} -> log_fn.("Warning: could not post PR comment (#{inspect(reason)})")
      end

      # If approved, mark the draft PR as ready for review
      if verdict == :approve do
        case Pyre.GitHub.mark_ready_for_review(owner, repo, pr_number, token) do
          :ok -> log_fn.("Marked PR as ready for review")
          {:error, reason} -> log_fn.("Warning: could not mark PR ready (#{inspect(reason)})")
        end
      end
    else
      log_fn.("Skipping GitHub PR review (not configured or no PR number)")
    end
  end
end
