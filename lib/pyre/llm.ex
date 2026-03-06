defmodule Pyre.LLM do
  @moduledoc """
  LLM abstraction layer using ReqLLM.

  Provides generate and stream functions that are provider-agnostic.
  Actions call through this module (or a mock implementing the same interface)
  via the `:llm` key in their context.
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

  @behaviour __MODULE__

  @impl true
  def generate(model, messages, opts \\ []) do
    context = build_context(messages)
    req_opts = Keyword.drop(opts, [:output_fn])

    case ReqLLM.generate_text(model, context, req_opts) do
      {:ok, text} -> {:ok, text}
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

  defp build_context(messages) do
    messages
    |> Enum.map(fn
      %{role: :system, content: content} -> %{role: "system", content: content}
      %{role: :user, content: content} -> %{role: "user", content: content}
      %{role: :assistant, content: content} -> %{role: "assistant", content: content}
    end)
  end
end
