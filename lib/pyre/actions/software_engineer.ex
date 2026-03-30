defmodule Pyre.Actions.SoftwareEngineer do
  @moduledoc """
  Implements all phases from the architecture plan in a single agentic session.

  Runs as a long-lived tool-use conversation that iterates through each phase:
  implementing code, writing tests, verifying acceptance criteria, updating
  the progress artifact, and committing per phase.
  """

  use Jido.Action,
    name: "software_engineer",
    description: "Implements all phases from the architecture plan with per-phase commits",
    schema: [
      feature_description: [type: :string, required: true],
      architecture_plan: [type: :string, required: true],
      pr_setup: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :software_engineer
  @summary_artifact "06_implementation_summary"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"03_architecture_plan.md", params.architecture_plan},
          {"04_pr_setup.md", params.pr_setup}
        ])

      user_msg =
        Persona.user_message(
          params.feature_description,
          artifacts_content,
          params.run_dir,
          "05_engineer_progress.md",
          attachments
        )

      working_dir = Map.get(context, :working_dir, ".")
      tool_opts = Helpers.tool_opts(context)
      tools = Pyre.Tools.for_role(:software_engineer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          {:ok, content} = Artifact.read_or_write(params.run_dir, @summary_artifact, text)
          {:ok, %{implementation_summary: content}}

        {:error, _} = error ->
          error
      end
    end
  end
end
