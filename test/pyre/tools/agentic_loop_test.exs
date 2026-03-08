defmodule Pyre.Tools.AgenticLoopTest do
  use ExUnit.Case, async: false

  alias Pyre.Tools.AgenticLoop

  # -- Helpers for building mock responses --

  defp final_answer_response(text) do
    %ReqLLM.Response{
      id: "mock_#{System.unique_integer([:positive])}",
      model: "mock",
      context: ReqLLM.Context.new(),
      finish_reason: :stop,
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
      }
    }
  end

  defp tool_call_response(text \\ "", tool_calls) do
    %ReqLLM.Response{
      id: "mock_#{System.unique_integer([:positive])}",
      model: "mock",
      context: ReqLLM.Context.new(),
      finish_reason: :tool_calls,
      message: %ReqLLM.Message{
        role: :assistant,
        content:
          if(text == "", do: [], else: [%ReqLLM.Message.ContentPart{type: :text, text: text}]),
        tool_calls: tool_calls
      }
    }
  end

  defp make_tool_call(name, args_map) do
    ReqLLM.ToolCall.new(
      "call_#{System.unique_integer([:positive])}",
      name,
      Jason.encode!(args_map)
    )
  end

  defp make_tool(name, callback) do
    %ReqLLM.Tool{
      name: name,
      description: "Test tool #{name}",
      parameter_schema: [input: [type: :string, required: true]],
      callback: callback
    }
  end

  # A mock LLM module that returns pre-configured responses from the process dictionary.
  # Similar to Pyre.LLM.Mock but returns pre-built ReqLLM.Response structs for chat/4.
  defmodule MockLLM do
    @behaviour Pyre.LLM

    @impl true
    def generate(_model, _messages, _opts \\ []), do: {:ok, "mock"}

    @impl true
    def stream(_model, _messages, _opts \\ []), do: {:ok, "mock"}

    @impl true
    def chat(_model, _messages, _tools, _opts \\ []) do
      case Process.get(:mock_chat_responses) do
        [response | rest] ->
          Process.put(:mock_chat_responses, rest)
          response

        [] ->
          {:error, "No more mock responses"}

        nil ->
          {:error, "No mock responses configured"}
      end
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:mock_chat_responses)
    end)
  end

  # -- Final Answer Tests --

  test "returns final answer text" do
    Process.put(:mock_chat_responses, [
      {:ok, final_answer_response("Hello, world!")}
    ])

    assert {:ok, "Hello, world!"} =
             AgenticLoop.run(MockLLM, "mock-model", [], [], log_fn: fn _ -> :ok end)
  end

  test "calls output_fn with final answer text" do
    Process.put(:mock_chat_responses, [
      {:ok, final_answer_response("Output text")}
    ])

    output = Agent.start_link(fn -> "" end) |> elem(1)

    AgenticLoop.run(MockLLM, "mock-model", [], [],
      output_fn: fn text -> Agent.update(output, &(&1 <> text)) end,
      log_fn: fn _ -> :ok end
    )

    assert Agent.get(output, & &1) == "Output text"
  end

  test "returns empty string for empty final answer" do
    Process.put(:mock_chat_responses, [
      {:ok, final_answer_response("")}
    ])

    assert {:ok, ""} =
             AgenticLoop.run(MockLLM, "mock-model", [], [], log_fn: fn _ -> :ok end)
  end

  # -- Tool Call Tests --

  test "executes tool calls and loops until final answer" do
    tool = make_tool("echo", fn %{input: input} -> {:ok, "echoed: #{input}"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("echo", %{input: "test"})])},
      {:ok, final_answer_response("Done")}
    ])

    assert {:ok, "Done"} =
             AgenticLoop.run(MockLLM, "mock-model", [], [tool], log_fn: fn _ -> :ok end)
  end

  test "accumulates text across turns" do
    tool = make_tool("noop", fn _ -> {:ok, "ok"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response("Thinking...", [make_tool_call("noop", %{input: "x"})])},
      {:ok, final_answer_response("Final.")}
    ])

    {:ok, result} =
      AgenticLoop.run(MockLLM, "mock-model", [], [tool], log_fn: fn _ -> :ok end)

    assert result == "Thinking...Final."
  end

  test "emits inter-turn text via output_fn" do
    tool = make_tool("noop", fn _ -> {:ok, "ok"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response("Step 1. ", [make_tool_call("noop", %{input: "x"})])},
      {:ok, final_answer_response("Step 2.")}
    ])

    chunks = Agent.start_link(fn -> [] end) |> elem(1)

    AgenticLoop.run(MockLLM, "mock-model", [], [tool],
      output_fn: fn text -> Agent.update(chunks, &(&1 ++ [text])) end,
      log_fn: fn _ -> :ok end
    )

    assert Agent.get(chunks, & &1) == ["Step 1. ", "Step 2."]
  end

  # -- Max Iterations --

  test "stops at max iterations" do
    tool = make_tool("noop", fn _ -> {:ok, "ok"} end)

    # Return tool calls forever
    responses =
      for _ <- 1..5 do
        {:ok, tool_call_response([make_tool_call("noop", %{input: "x"})])}
      end

    Process.put(:mock_chat_responses, responses)

    {:ok, result} =
      AgenticLoop.run(MockLLM, "mock-model", [], [tool],
        max_iterations: 3,
        log_fn: fn _ -> :ok end
      )

    assert result =~ "Reached maximum tool-use iterations"
  end

  # -- Error Handling --

  test "returns error when LLM chat fails" do
    Process.put(:mock_chat_responses, [
      {:error, "LLM connection failed"}
    ])

    assert {:error, "LLM connection failed"} =
             AgenticLoop.run(MockLLM, "mock-model", [], [], log_fn: fn _ -> :ok end)
  end

  test "handles tool not found gracefully" do
    # LLM calls a tool that doesn't exist
    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("nonexistent", %{input: "x"})])},
      {:ok, final_answer_response("I apologize")}
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    {:ok, _result} =
      AgenticLoop.run(MockLLM, "mock-model", [], [],
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )

    log_output = Agent.get(logs, & &1) |> Enum.join("\n")
    assert log_output =~ "tool error"
    assert log_output =~ "nonexistent"
    assert log_output =~ "not found"
  end

  test "includes tool schema in error message when tool execution fails" do
    tool = make_tool("strict_tool", fn _args -> {:error, "validation failed"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("strict_tool", %{input: "bad"})])},
      {:ok, final_answer_response("Fixed")}
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    {:ok, _result} =
      AgenticLoop.run(MockLLM, "mock-model", [], [tool],
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )

    log_output = Agent.get(logs, & &1) |> Enum.join("\n")
    assert log_output =~ "tool error"
    assert log_output =~ "Expected parameters"
    assert log_output =~ "input"
  end

  # -- Logging --

  test "logs tool call names" do
    tool = make_tool("my_tool", fn _ -> {:ok, "result"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("my_tool", %{input: "val"})])},
      {:ok, final_answer_response("Done")}
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    AgenticLoop.run(MockLLM, "mock-model", [], [tool],
      log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
    )

    log_output = Agent.get(logs, & &1) |> Enum.join("\n")
    assert log_output =~ "my_tool"
    assert log_output =~ "input"
  end

  test "verbose mode logs full argument details" do
    tool = make_tool("my_tool", fn _ -> {:ok, "result"} end)

    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("my_tool", %{input: "hello"})])},
      {:ok, final_answer_response("Done")}
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    AgenticLoop.run(MockLLM, "mock-model", [], [tool],
      verbose: true,
      log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
    )

    log_output = Agent.get(logs, & &1) |> Enum.join("\n")
    assert log_output =~ "input:"
    assert log_output =~ "hello"
    # Verbose also logs tool results
    assert log_output =~ "tool result"
  end

  test "logs EMPTY ARGS when tool called with no arguments" do
    Process.put(:mock_chat_responses, [
      {:ok, tool_call_response([make_tool_call("my_tool", %{})])},
      {:ok, final_answer_response("Done")}
    ])

    tool = make_tool("my_tool", fn _ -> {:ok, "ok"} end)
    logs = Agent.start_link(fn -> [] end) |> elem(1)

    AgenticLoop.run(MockLLM, "mock-model", [], [tool],
      log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
    )

    log_output = Agent.get(logs, & &1) |> Enum.join("\n")
    assert log_output =~ "EMPTY ARGS"
  end

  # -- Multiple tool calls in one turn --

  test "executes multiple tool calls in a single turn" do
    tool_a = make_tool("tool_a", fn _ -> {:ok, "result_a"} end)
    tool_b = make_tool("tool_b", fn _ -> {:ok, "result_b"} end)

    Process.put(:mock_chat_responses, [
      {:ok,
       tool_call_response([
         make_tool_call("tool_a", %{input: "x"}),
         make_tool_call("tool_b", %{input: "y"})
       ])},
      {:ok, final_answer_response("Both done")}
    ])

    assert {:ok, "Both done"} =
             AgenticLoop.run(MockLLM, "mock-model", [], [tool_a, tool_b], log_fn: fn _ -> :ok end)
  end
end
