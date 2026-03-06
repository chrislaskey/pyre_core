defmodule Pyre.Plugins.PersonaTest do
  use ExUnit.Case, async: true

  alias Pyre.Plugins.Persona

  describe "load/1" do
    test "loads product_manager persona" do
      assert {:ok, content} = Persona.load(:product_manager)
      assert is_binary(content)
      assert String.contains?(content, "#")
    end

    test "loads designer persona" do
      assert {:ok, content} = Persona.load(:designer)
      assert is_binary(content)
    end

    test "loads programmer persona" do
      assert {:ok, content} = Persona.load(:programmer)
      assert is_binary(content)
    end

    test "loads test_writer persona" do
      assert {:ok, content} = Persona.load(:test_writer)
      assert is_binary(content)
    end

    test "loads code_reviewer persona" do
      assert {:ok, content} = Persona.load(:code_reviewer)
      assert is_binary(content)
    end

    test "returns error for nonexistent persona" do
      assert {:error, :enoent} = Persona.load(:nonexistent)
    end
  end

  describe "system_message/1" do
    test "returns a system role message map" do
      assert {:ok, msg} = Persona.system_message(:product_manager)
      assert msg.role == :system
      assert is_binary(msg.content)
      assert String.contains?(msg.content, "#")
    end

    test "returns error for nonexistent persona" do
      assert {:error, :enoent} = Persona.system_message(:nonexistent)
    end
  end

  describe "user_message/4" do
    test "includes feature description" do
      msg = Persona.user_message("Build products", "", "/tmp/run", "01_req.md")
      assert msg.role == :user
      assert String.contains?(msg.content, "Build products")
    end

    test "includes artifacts when provided" do
      msg = Persona.user_message("Feature", "Prior artifact content", "/tmp/run", "02.md")
      assert String.contains?(msg.content, "Prior artifact content")
      assert String.contains?(msg.content, "Prior Artifacts")
    end

    test "omits artifacts section when content is empty" do
      msg = Persona.user_message("Feature", "", "/tmp/run", "01.md")
      refute String.contains?(msg.content, "Prior Artifacts")
    end

    test "includes output instructions with file path" do
      msg = Persona.user_message("Feature", "", "/tmp/run", "01_req.md")
      assert String.contains?(msg.content, "/tmp/run/01_req.md")
      assert String.contains?(msg.content, "Output Instructions")
    end
  end
end
