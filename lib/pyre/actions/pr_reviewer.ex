defmodule Pyre.Actions.PRReviewer do
  @moduledoc """
  Reviews the complete PR and posts a GitHub review comment.

  Reuses the code_reviewer persona to evaluate all implementation phases,
  then posts an APPROVE or REQUEST_CHANGES review on the GitHub PR.
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

          maybe_post_review(verdict, text, params, context)

          {:ok, %{review: text, verdict: verdict}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp maybe_post_review(verdict, text, params, context) do
    github = Map.get(context, :github, %{})
    pr_number = Map.get(params, :pr_number)
    log_fn = Map.get(context, :log_fn, &IO.puts/1)

    if pr_number && github[:owner] && github[:repo] && github[:token] do
      event = if verdict == :approve, do: "APPROVE", else: "REQUEST_CHANGES"

      case Pyre.GitHub.create_review(
             github[:owner],
             github[:repo],
             pr_number,
             text,
             event,
             github[:token]
           ) do
        {:ok, _} -> log_fn.("Posted PR review: #{event}")
        {:error, reason} -> log_fn.("Warning: could not post PR review (#{inspect(reason)})")
      end
    else
      log_fn.("Skipping GitHub PR review (not configured or no PR number)")
    end
  end
end
