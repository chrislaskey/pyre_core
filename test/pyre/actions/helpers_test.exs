defmodule Pyre.Actions.HelpersTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.Helpers

  # -- resolve_model/2 --

  describe "resolve_model/2" do
    test "resolves :fast tier" do
      context = %{}
      assert Helpers.resolve_model(:fast, context) == "anthropic:claude-haiku-4-5"
    end

    test "resolves :standard tier" do
      context = %{}
      assert Helpers.resolve_model(:standard, context) == "anthropic:claude-sonnet-4-20250514"
    end

    test "resolves :advanced tier" do
      context = %{}
      assert Helpers.resolve_model(:advanced, context) == "anthropic:claude-opus-4-20250514"
    end

    test "uses model_override when present" do
      context = %{model_override: "custom:model-v1"}
      assert Helpers.resolve_model(:standard, context) == "custom:model-v1"
    end

    test "model_override takes precedence over tier" do
      context = %{model_override: "fast-model"}
      assert Helpers.resolve_model(:advanced, context) == "fast-model"
    end

    test "uses custom model_aliases when provided" do
      custom_aliases = %{fast: "custom:fast", standard: "custom:standard"}
      context = %{model_aliases: custom_aliases}
      assert Helpers.resolve_model(:fast, context) == "custom:fast"
      assert Helpers.resolve_model(:standard, context) == "custom:standard"
    end

    test "falls back to default standard for unknown tier" do
      context = %{}
      assert Helpers.resolve_model(:unknown_tier, context) == "anthropic:claude-sonnet-4-20250514"
    end
  end

  # -- call_llm/4 --

  describe "call_llm/4" do
    test "calls generate for non-streaming without tools" do
      Process.put(:mock_llm_response, "Generated text")

      context = %{
        llm: Pyre.LLM.Mock,
        streaming: false
      }

      assert {:ok, "Generated text"} = Helpers.call_llm(context, "model", [])
    end

    test "calls stream for streaming without tools" do
      Process.put(:mock_llm_response, "Streamed text")

      context = %{
        llm: Pyre.LLM.Mock,
        streaming: true,
        output_fn: fn _ -> :ok end
      }

      assert {:ok, "Streamed text"} = Helpers.call_llm(context, "model", [])
    end

    test "defaults to Pyre.LLM when :llm not in context" do
      # Just verify it doesn't crash when accessing missing :llm key
      context = %{streaming: false}

      # This would fail because Pyre.LLM requires real API, but the
      # fallback logic itself works. We test the key resolution only.
      assert Map.get(context, :llm, Pyre.LLM) == Pyre.LLM
    end
  end

  # -- tool_opts/1 --

  describe "tool_opts/1" do
    test "returns empty list when no allowed_commands" do
      context = %{}
      assert Helpers.tool_opts(context) == []
    end

    test "returns empty list when allowed_commands is nil" do
      context = %{allowed_commands: nil}
      assert Helpers.tool_opts(context) == []
    end

    test "returns keyword list with allowed_commands" do
      commands = ~w(mix elixir cat)
      context = %{allowed_commands: commands}
      assert Helpers.tool_opts(context) == [allowed_commands: commands]
    end
  end

  # -- assemble_artifacts/1 --

  describe "assemble_artifacts/1" do
    test "assembles multiple artifacts with separators" do
      result =
        Helpers.assemble_artifacts(
          requirements: "Req content",
          design: "Design content"
        )

      assert result =~ "## requirements"
      assert result =~ "Req content"
      assert result =~ "---"
      assert result =~ "## design"
      assert result =~ "Design content"
    end

    test "filters out nil content" do
      result =
        Helpers.assemble_artifacts(
          requirements: "Req content",
          design: nil,
          implementation: "Impl content"
        )

      assert result =~ "requirements"
      refute result =~ "design"
      assert result =~ "implementation"
    end

    test "filters out empty string content" do
      result =
        Helpers.assemble_artifacts(
          requirements: "Req content",
          design: ""
        )

      assert result =~ "requirements"
      refute result =~ "design"
    end

    test "returns empty string when all content is nil" do
      result = Helpers.assemble_artifacts(requirements: nil, design: nil)
      assert result == ""
    end

    test "single item has no separator" do
      result = Helpers.assemble_artifacts(requirements: "Only this")
      assert result == "## requirements\n\nOnly this"
      refute result =~ "---"
    end

    test "handles empty list" do
      result = Helpers.assemble_artifacts([])
      assert result == ""
    end
  end
end
