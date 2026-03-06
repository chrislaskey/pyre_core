defmodule Pyre.Actions.Programmer do
  @moduledoc """
  Implements features based on requirements and design spec.

  Loads the programmer persona, calls the LLM with all prior context,
  and writes a versioned implementation summary artifact.
  """

  use Jido.Action,
    name: "programmer",
    description: "Implements the feature using Phoenix conventions and Pyre generators",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      run_dir: [type: :string, required: true],
      review_cycle: [type: :integer, default: 1],
      previous_verdict: [type: :string, doc: "Previous review verdict text for rework cycles"]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :programmer
  @artifact_base "03_implementation_summary"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)
    cycle = Map.get(params, :review_cycle, 1)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      prior = [
        {"01_requirements.md", params.requirements},
        {"02_design_spec.md", params.design}
      ]

      prior =
        if params[:previous_verdict] do
          prior ++ [{"previous_review_verdict.md", params.previous_verdict}]
        else
          prior
        end

      artifacts_content = Helpers.assemble_artifacts(prior)
      artifact_name = Artifact.versioned_name(@artifact_base, cycle)

      user_msg =
        Persona.user_message(
          params.feature_description,
          artifacts_content,
          params.run_dir,
          "#{artifact_name}.md"
        )

      working_dir = Map.get(context, :working_dir, ".")
      tool_opts = Helpers.tool_opts(context)
      tools = Pyre.Tools.for_role(:programmer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, artifact_name, text)
          {:ok, %{implementation: text}}

        {:error, _} = error ->
          error
      end
    end
  end
end
