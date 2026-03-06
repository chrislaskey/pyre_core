defmodule Pyre.LLM.Mock do
  @moduledoc """
  Mock LLM module for testing.

  Returns responses configured via `Process.put(:mock_llm_response, "...")`.
  For sequenced responses, use `Process.put(:mock_llm_responses, ["r1", "r2", ...])`.
  """

  @behaviour Pyre.LLM

  @impl true
  def generate(_model, _messages, _opts \\ []) do
    {:ok, next_response()}
  end

  @impl true
  def stream(_model, _messages, _opts \\ []) do
    {:ok, next_response()}
  end

  defp next_response do
    case Process.get(:mock_llm_responses) do
      [response | rest] ->
        Process.put(:mock_llm_responses, rest)
        response

      [] ->
        "Mock response (exhausted)"

      nil ->
        Process.get(:mock_llm_response, "Mock response")
    end
  end
end
