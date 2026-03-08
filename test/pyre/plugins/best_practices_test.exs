defmodule Pyre.Plugins.BestPracticesTest do
  use ExUnit.Case, async: true

  alias Pyre.Plugins.BestPractices

  describe "load/1" do
    test "loads product_manager best practices" do
      assert {:ok, content} = BestPractices.load(:product_manager)
      assert is_binary(content)
      assert String.contains?(content, "Best Practices")
    end

    test "loads designer best practices" do
      assert {:ok, content} = BestPractices.load(:designer)
      assert is_binary(content)
    end

    test "loads programmer best practices" do
      assert {:ok, content} = BestPractices.load(:programmer)
      assert is_binary(content)
    end

    test "loads test_writer best practices" do
      assert {:ok, content} = BestPractices.load(:test_writer)
      assert is_binary(content)
    end

    test "loads code_reviewer best practices" do
      assert {:ok, content} = BestPractices.load(:code_reviewer)
      assert is_binary(content)
    end

    test "returns error for nonexistent role" do
      assert {:error, :enoent} = BestPractices.load(:nonexistent)
    end
  end

  describe "fallback_text/1" do
    test "returns file content for known roles" do
      text = BestPractices.fallback_text(:designer)
      assert is_binary(text)
      assert String.contains?(text, "Best Practices")
    end

    test "returns generic fallback for unknown roles" do
      text = BestPractices.fallback_text(:nonexistent)
      assert text == "No specific guidelines provided. Use general best practices."
    end
  end
end
