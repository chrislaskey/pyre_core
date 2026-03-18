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

  When `tools:` option is provided and the backend manages its own tool loop
  (e.g., `Pyre.LLM.ClaudeCLI`), calls `chat/4` directly. Otherwise delegates
  to `Pyre.Tools.AgenticLoop` for multi-turn tool-use conversations.
  """
  def call_llm(context, model, messages, opts \\ []) do
    llm = Map.get(context, :llm, Pyre.LLM.default())
    streaming? = Map.get(context, :streaming, true)
    tools = Keyword.get(opts, :tools, [])

    cond do
      tools != [] and manages_tool_loop?(llm) ->
        llm.chat(model, messages, tools, cli_opts(context))

      tools != [] ->
        output_fn = Map.get(context, :output_fn, &IO.write/1)
        log_fn = Map.get(context, :log_fn, &IO.puts/1)
        verbose? = Map.get(context, :verbose, false)

        Pyre.Tools.AgenticLoop.run(llm, model, messages, tools,
          streaming: streaming?,
          output_fn: output_fn,
          log_fn: log_fn,
          verbose: verbose?
        )

      streaming? ->
        output_fn = Map.get(context, :output_fn, &IO.write/1)
        llm.stream(model, messages, output_fn: output_fn)

      true ->
        llm.generate(model, messages, [])
    end
  end

  defp manages_tool_loop?(llm) do
    function_exported?(llm, :manages_tool_loop?, 0) and llm.manages_tool_loop?()
  end

  defp cli_opts(context) do
    [
      streaming: Map.get(context, :streaming, true),
      output_fn: Map.get(context, :output_fn, &IO.write/1),
      working_dir: Map.get(context, :working_dir),
      verbose: Map.get(context, :verbose, false),
      max_turns: Map.get(context, :max_turns, 50),
      add_dirs: Map.get(context, :add_dirs, [])
    ]
  end

  @doc """
  Builds tool options from the flow context.

  Extracts `:allowed_commands` and `:allowed_paths` when present,
  returning a keyword list suitable for passing to `Pyre.Tools.for_role/3`.
  """
  def tool_opts(context) do
    opts = []

    opts =
      case Map.get(context, :allowed_commands) do
        nil -> opts
        commands -> Keyword.put(opts, :allowed_commands, commands)
      end

    case Map.get(context, :allowed_paths) do
      nil -> opts
      paths -> Keyword.put(opts, :allowed_paths, paths)
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
