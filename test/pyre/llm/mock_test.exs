defmodule Pyre.LLM.MockTest do
  use ExUnit.Case, async: false

  alias Pyre.LLM.Mock

  setup do
    on_exit(fn ->
      Process.delete(:mock_llm_response)
      Process.delete(:mock_llm_responses)
    end)
  end

  describe "generate/3" do
    test "returns single configured response" do
      Process.put(:mock_llm_response, "Hello from mock")
      assert {:ok, "Hello from mock"} = Mock.generate("model", [])
    end

    test "returns default when nothing configured" do
      assert {:ok, "Mock response"} = Mock.generate("model", [])
    end
  end

  describe "stream/3" do
    test "returns single configured response" do
      Process.put(:mock_llm_response, "Streamed mock")
      assert {:ok, "Streamed mock"} = Mock.stream("model", [])
    end
  end

  describe "sequenced responses" do
    test "returns responses in order" do
      Process.put(:mock_llm_responses, ["first", "second", "third"])

      assert {:ok, "first"} = Mock.generate("model", [])
      assert {:ok, "second"} = Mock.generate("model", [])
      assert {:ok, "third"} = Mock.generate("model", [])
    end

    test "returns exhausted message when list is empty" do
      Process.put(:mock_llm_responses, ["only one"])

      assert {:ok, "only one"} = Mock.generate("model", [])
      assert {:ok, "Mock response (exhausted)"} = Mock.generate("model", [])
    end

    test "sequenced responses take precedence over single response" do
      Process.put(:mock_llm_response, "single")
      Process.put(:mock_llm_responses, ["sequenced"])

      assert {:ok, "sequenced"} = Mock.generate("model", [])
      # After exhausting the sequence, returns exhausted message (not single)
      assert {:ok, "Mock response (exhausted)"} = Mock.generate("model", [])
    end
  end

  describe "chat/4" do
    test "returns a ReqLLM.Response struct" do
      Process.put(:mock_llm_response, "Chat response")

      assert {:ok, %ReqLLM.Response{} = response} = Mock.chat("model", [], [])
      assert response.model == "mock"
      assert response.finish_reason == :stop
    end

    test "response has text content" do
      Process.put(:mock_llm_response, "My chat text")

      {:ok, response} = Mock.chat("model", [], [])
      text = ReqLLM.Response.text(response)
      assert text == "My chat text"
    end

    test "response classifies as final_answer" do
      Process.put(:mock_llm_response, "Final answer text")

      {:ok, response} = Mock.chat("model", [], [])
      classified = ReqLLM.Response.classify(response)
      assert classified.type == :final_answer
      assert classified.text == "Final answer text"
    end

    test "chat uses sequenced responses" do
      Process.put(:mock_llm_responses, ["first chat", "second chat"])

      {:ok, r1} = Mock.chat("model", [], [])
      {:ok, r2} = Mock.chat("model", [], [])

      assert ReqLLM.Response.text(r1) == "first chat"
      assert ReqLLM.Response.text(r2) == "second chat"
    end
  end
end
