defmodule Pyre.LLM do
  @moduledoc """
  LLM abstraction layer using ReqLLM.

  Provides generate, stream, and chat functions that are provider-agnostic.
  Actions call through this module (or a mock implementing the same interface)
  via the `:llm` key in their context.

  - `generate/3` and `stream/3` return `{:ok, text}` for simple text-only flows.
  - `chat/4` returns `{:ok, ReqLLM.Response.t()}` for tool-use flows that need
    the full response (tool_calls, finish_reason, updated context).
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type model :: String.t()

  @doc """
  Generates text from the LLM without streaming.
  """
  @callback generate(model(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Generates text from the LLM with token-by-token streaming.

  Calls `output_fn` (default `&IO.write/1`) with each token as it arrives.
  Returns the complete response text.
  """
  @callback stream(model(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Calls the LLM with tool support, returning the full response.

  Used by the agentic loop for multi-turn tool-use conversations.
  Supports both streaming and non-streaming via the `:streaming` option.

  Options:
    - `:tools` - list of `ReqLLM.Tool.t()` structs
    - `:streaming` - boolean, default `false`
    - `:output_fn` - streaming token callback, default `&IO.write/1`
  """
  @callback chat(model(), [message()] | ReqLLM.Context.t(), [ReqLLM.Tool.t()], keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def generate(model, messages, opts \\ []) do
    context = build_context(messages)
    req_opts = Keyword.drop(opts, [:output_fn])

    case ReqLLM.generate_text(model, context, req_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.text(response)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    context = build_context(messages)
    req_opts = Keyword.drop(opts, [:output_fn])

    case ReqLLM.stream_text(model, context, req_opts) do
      {:ok, response} ->
        text =
          response
          |> ReqLLM.StreamResponse.tokens()
          |> Stream.each(output_fn)
          |> Enum.join("")

        {:ok, text}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def chat(model, messages, tools, opts \\ []) do
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)

    context =
      case messages do
        %ReqLLM.Context{} -> messages
        msgs when is_list(msgs) -> build_reqllm_context(msgs)
      end

    req_opts = [tools: tools] ++ Keyword.drop(opts, [:streaming, :output_fn, :tools])

    if streaming? do
      chat_streaming(model, context, req_opts, output_fn)
    else
      chat_non_streaming(model, context, req_opts)
    end
  end

  defp chat_non_streaming(model, context, req_opts) do
    case ReqLLM.generate_text(model, context, req_opts) do
      {:ok, %ReqLLM.Response{}} = ok -> ok
      {:error, _} = error -> error
    end
  end

  defp chat_streaming(model, context, req_opts, output_fn) do
    case ReqLLM.stream_text(model, context, req_opts) do
      {:ok, stream_response} ->
        ReqLLM.StreamResponse.process_stream(stream_response, on_result: output_fn)

      {:error, _} = error ->
        error
    end
  end

  # Builds a simple list-of-maps context for generate/stream (existing behavior)
  defp build_context(messages) do
    messages
    |> Enum.map(fn
      %{role: :system, content: content} -> %{role: "system", content: content}
      %{role: :user, content: content} -> %{role: "user", content: content}
      %{role: :assistant, content: content} -> %{role: "assistant", content: content}
    end)
  end

  # Builds a proper ReqLLM.Context for chat/4 (tool-use needs structured context)
  defp build_reqllm_context(messages) do
    msgs =
      Enum.map(messages, fn
        %{role: :system, content: content} -> ReqLLM.Context.system(content)
        %{role: :user, content: content} -> ReqLLM.Context.user(content)
      end)

    ReqLLM.Context.new(msgs)
  end
end
