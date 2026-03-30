defmodule Pyre.Actions.TestWriter do
  @moduledoc """
  Creates comprehensive tests for the implementation.

  Loads the test_writer persona, calls the LLM with all prior context
  including implementation, and writes a versioned test summary artifact.
  """

  use Jido.Action,
    name: "test_writer",
    description: "Writes comprehensive ExUnit tests for the implementation",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      implementation: [type: :string, required: true],
      run_dir: [type: :string, required: true],
      review_cycle: [type: :integer, default: 1],
      previous_verdict: [type: :string, doc: "Previous review verdict text for rework cycles"]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :test_writer
  @artifact_base "04_test_summary"
  @model_tier :standard

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)
    cycle = Map.get(params, :review_cycle, 1)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      prior = [
        {"01_requirements.md", params.requirements},
        {"02_design_spec.md", params.design},
        {"03_implementation_summary.md", params.implementation}
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
          "#{artifact_name}.md",
          attachments
        )

      working_dir = Map.get(context, :working_dir, ".")
      tool_opts = Helpers.tool_opts(context)
      tools = Pyre.Tools.for_role(:test_writer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          {:ok, content} = Artifact.read_or_write(params.run_dir, artifact_name, text)
          {:ok, %{tests: content}}

        {:error, _} = error ->
          error
      end
    end
  end
end
