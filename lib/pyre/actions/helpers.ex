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

  When `tools:` option is provided, delegates to the agentic loop for
  multi-turn tool-use conversations.
  """
  def call_llm(context, model, messages, opts \\ []) do
    llm = Map.get(context, :llm, Pyre.LLM)
    streaming? = Map.get(context, :streaming, true)
    tools = Keyword.get(opts, :tools, [])

    if tools != [] do
      output_fn = Map.get(context, :output_fn, &IO.write/1)
      verbose? = Map.get(context, :verbose, false)

      Pyre.Tools.AgenticLoop.run(llm, model, messages, tools,
        streaming: streaming?,
        output_fn: output_fn,
        verbose: verbose?
      )
    else
      if streaming? do
        output_fn = Map.get(context, :output_fn, &IO.write/1)
        llm.stream(model, messages, output_fn: output_fn)
      else
        llm.generate(model, messages, [])
      end
    end
  end

  @doc """
  Builds tool options from the flow context.

  Extracts `:allowed_commands` when present, returning a keyword list
  suitable for passing to `Pyre.Tools.for_role/3`.
  """
  def tool_opts(context) do
    case Map.get(context, :allowed_commands) do
      nil -> []
      commands -> [allowed_commands: commands]
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
