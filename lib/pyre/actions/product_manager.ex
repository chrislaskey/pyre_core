defmodule Pyre.Actions.ProductManager do
  @moduledoc """
  Generates requirements from a feature description.

  Loads the product_manager persona, calls the LLM, and writes
  the requirements artifact to the run directory.
  """

  use Jido.Action,
    name: "product_manager",
    description: "Translates feature request into requirements and user stories",
    schema: [
      feature_description: [type: :string, required: true],
      run_dir: [type: :string, required: true]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :product_manager
  @artifact_base "01_requirements"
  @model_tier :standard

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      user_msg =
        Persona.user_message(
          params.feature_description,
          "",
          params.run_dir,
          "#{@artifact_base}.md"
        )

      case Helpers.call_llm(context, model, [system_msg, user_msg]) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, @artifact_base, text)
          {:ok, %{requirements: text}}

        {:error, _} = error ->
          error
      end
    end
  end
end
