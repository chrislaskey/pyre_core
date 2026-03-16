defmodule Pyre.Actions.Designer do
  @moduledoc """
  Creates UI/UX design spec from requirements.

  Loads the designer persona, calls the LLM with requirements context,
  and writes the design spec artifact.
  """

  use Jido.Action,
    name: "designer",
    description: "Creates UI/UX design specification from requirements",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :designer
  @artifact_base "02_design_spec"
  @model_tier :standard

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"01_requirements.md", params.requirements}
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
      tools = Pyre.Tools.for_role(:designer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, @artifact_base, text)
          {:ok, %{design: text}}

        {:error, _} = error ->
          error
      end
    end
  end
end
