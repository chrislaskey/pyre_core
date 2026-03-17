defmodule Pyre.Actions.SoftwareArchitect do
  @moduledoc """
  Decomposes a feature into a multi-phase implementation plan.

  Loads the software_architect persona, explores the codebase with read-only
  tools, and produces a phased plan with acceptance criteria for each phase.
  """

  use Jido.Action,
    name: "software_architect",
    description: "Decomposes feature into multi-phase implementation plan",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :software_architect
  @artifact_base "03_architecture_plan"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"01_requirements.md", params.requirements},
          {"02_design_spec.md", params.design}
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
      tools = Pyre.Tools.for_role(:software_architect, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, @artifact_base, text)
          {:ok, %{architecture_plan: text}}

        {:error, _} = error ->
          error
      end
    end
  end
end
