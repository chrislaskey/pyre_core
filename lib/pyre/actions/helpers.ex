defmodule Pyre.Actions.Helpers do
  @moduledoc false

  @model_aliases %{
    fast: "anthropic:claude-haiku-4-5",
    standard: "anthropic:claude-sonnet-4-20250514",
    advanced: "anthropic:claude-opus-4-20250514"
  }

  @doc """
  Resolves a model tier atom to a full model string.
  Respects `:model_override` in context (used by --fast flag).
  """
  def resolve_model(tier, context) do
    case Map.get(context, :model_override) do
      nil ->
        aliases = Map.get(context, :model_aliases, @model_aliases)
        Map.get(aliases, tier, @model_aliases[:standard])

      override ->
        override
    end
  end

  @doc """
  Calls the LLM via the module in context, respecting streaming preference.
  """
  def call_llm(context, model, messages) do
    llm = Map.get(context, :llm, Pyre.LLM)
    streaming? = Map.get(context, :streaming, true)

    if streaming? do
      output_fn = Map.get(context, :output_fn, &IO.write/1)
      llm.stream(model, messages, output_fn: output_fn)
    else
      llm.generate(model, messages, [])
    end
  end

  @doc """
  Builds the assembled artifacts string from a keyword list of named content.
  """
  def assemble_artifacts(artifacts) do
    artifacts
    |> Enum.reject(fn {_name, content} -> is_nil(content) or content == "" end)
    |> Enum.map(fn {name, content} -> "## #{name}\n\n#{content}" end)
    |> Enum.join("\n\n---\n\n")
  end
end
