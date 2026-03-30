defmodule Pyre.Actions.PrototypeEngineer do
  @moduledoc """
  Rapid prototyping agent that builds a working proof-of-concept.

  Loads the prototype_engineer persona, calls the LLM with full tools,
  and writes the output artifact to the run directory.
  """

  use Jido.Action,
    name: "prototype_engineer",
    description: "Rapidly builds a working prototype focusing on core functionality",
    schema: [
      feature_description: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :prototype_engineer
  @artifact_base "01_prototype_output"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      user_msg =
        Persona.user_message(
          params.feature_description,
          "",
          params.run_dir,
          "#{@artifact_base}.md",
          attachments
        )

      working_dir = Map.get(context, :working_dir, ".")
      tool_opts = Helpers.tool_opts(context)
      tools = Pyre.Tools.for_role(:prototype_engineer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          {:ok, content} = Artifact.read_or_write(params.run_dir, @artifact_base, text)
          {:ok, %{prototype_output: content}}

        {:error, _} = error ->
          error
      end
    end
  end
end
