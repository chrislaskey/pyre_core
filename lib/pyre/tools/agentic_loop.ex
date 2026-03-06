defmodule Pyre.Tools.AgenticLoop do
  @moduledoc """
  Multi-turn tool-use conversation loop.

  Repeatedly calls the LLM with tools, executes any tool calls from the
  response, appends results to the conversation, and continues until the
  LLM produces a final text answer or the iteration limit is reached.
  """

  @max_iterations 25
  @default_receive_timeout 300_000

  @doc """
  Runs the agentic loop until the LLM produces a final answer.

  Returns `{:ok, final_text}` with the accumulated text from all turns.

  ## Options

    * `:streaming` - Stream tokens via `output_fn`. Default `false`.
    * `:output_fn` - Token callback for streaming. Default `&IO.write/1`.
    * `:max_iterations` - Max tool-use turns. Default `25`.
    * `:verbose` - Log tool calls. Default `false`.
    * `:receive_timeout` - Per-chunk timeout in ms. Default `300_000` (5 min).
  """
  @spec run(module(), String.t(), [map()], [ReqLLM.Tool.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(llm_module, model, messages, tools, opts \\ []) do
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    verbose? = Keyword.get(opts, :verbose, false)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    loop(llm_module, model, messages, tools, 0, max_iter, streaming?, output_fn, verbose?, receive_timeout, "")
  end

  defp loop(
         _llm,
         _model,
         _messages,
         _tools,
         iteration,
         max_iter,
         _streaming?,
         _output_fn,
         _verbose?,
         _receive_timeout,
         accumulated
       )
       when iteration >= max_iter do
    {:ok, accumulated <> "\n\n(Reached maximum tool-use iterations)"}
  end

  defp loop(
         llm_module,
         model,
         messages,
         tools,
         iteration,
         max_iter,
         streaming?,
         output_fn,
         verbose?,
         receive_timeout,
         accumulated
       ) do
    chat_opts = [
      streaming: streaming?,
      output_fn: output_fn,
      receive_timeout: receive_timeout
    ]

    case llm_module.chat(model, messages, tools, chat_opts) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)

        handle_classified(
          classified,
          response,
          llm_module,
          model,
          tools,
          iteration,
          max_iter,
          streaming?,
          output_fn,
          verbose?,
          receive_timeout,
          accumulated
        )

      {:error, _} = error ->
        error
    end
  end

  defp handle_classified(
         %{type: :final_answer, text: text},
         _response,
         _llm,
         _model,
         _tools,
         _iteration,
         _max_iter,
         _streaming?,
         _output_fn,
         _verbose?,
         _receive_timeout,
         accumulated
       ) do
    {:ok, accumulated <> text}
  end

  defp handle_classified(
         %{type: :tool_calls, text: text, tool_calls: tool_calls},
         response,
         llm_module,
         model,
         tools,
         iteration,
         max_iter,
         streaming?,
         output_fn,
         verbose?,
         receive_timeout,
         accumulated
       ) do
    if verbose?, do: log_tool_calls(tool_calls, iteration)

    # The response.context already includes the assistant message with tool calls.
    # Execute tools and append results to get the updated context.
    updated_context =
      ReqLLM.Context.execute_and_append_tools(response.context, tool_calls, tools)

    loop(
      llm_module,
      model,
      updated_context,
      tools,
      iteration + 1,
      max_iter,
      streaming?,
      output_fn,
      verbose?,
      receive_timeout,
      accumulated <> text
    )
  end

  defp log_tool_calls(tool_calls, iteration) do
    Enum.each(tool_calls, fn tc ->
      name = Map.get(tc, :name, "unknown")
      Mix.shell().info("[tool #{iteration + 1}] #{name}")
    end)
  end
end
