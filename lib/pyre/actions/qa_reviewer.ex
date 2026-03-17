defmodule Pyre.Actions.QAReviewer do
  @moduledoc """
  Reviews code and tests for quality, correctness, and standards.

  Loads the code_reviewer persona, calls the LLM with all prior context,
  writes a versioned review verdict artifact, and parses the APPROVE/REJECT
  verdict from the first line.
  """

  use Jido.Action,
    name: "qa_reviewer",
    description: "Reviews implementation and tests, issues APPROVE or REJECT verdict",
    schema: [
      feature_description: [type: :string, required: true],
      requirements: [type: :string, required: true],
      design: [type: :string, required: true],
      implementation: [type: :string, required: true],
      tests: [type: :string, required: true],
      run_dir: [type: :string, required: true],
      review_cycle: [type: :integer, default: 1]
    ]

  alias Pyre.Actions.Helpers
  alias Pyre.Plugins.{Artifact, Persona}

  @persona :code_reviewer
  @artifact_base "05_review_verdict"
  @model_tier :advanced

  @impl true
  def run(params, context) do
    model = Helpers.resolve_model(@model_tier, context)
    cycle = Map.get(params, :review_cycle, 1)

    with {:ok, system_msg} <- Persona.system_message(@persona) do
      attachments = Map.get(params, :attachments, [])

      artifacts_content =
        Helpers.assemble_artifacts([
          {"01_requirements.md", params.requirements},
          {"02_design_spec.md", params.design},
          {"03_implementation_summary.md", params.implementation},
          {"04_test_summary.md", params.tests}
        ])

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
      tools = Pyre.Tools.for_role(:qa_reviewer, working_dir, tool_opts)

      case Helpers.call_llm(context, model, [system_msg, user_msg], tools: tools) do
        {:ok, text} ->
          :ok = Artifact.write(params.run_dir, artifact_name, text)
          verdict = parse_verdict(text)
          {:ok, %{verdict: verdict, verdict_text: text}}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc false
  def parse_verdict(text) do
    verdict_line =
      text
      |> String.split("\n")
      |> Enum.find("", fn line ->
        trimmed = String.trim(line)
        String.match?(trimmed, ~r/^APPROVE/i) or String.match?(trimmed, ~r/^REJECT/i)
      end)

    if String.match?(String.trim(verdict_line), ~r/^APPROVE/i), do: :approve, else: :reject
  end
end
