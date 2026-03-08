defmodule Pyre.ToolsTest do
  use ExUnit.Case, async: true

  alias Pyre.Tools

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pyre_tools_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{dir: tmp_dir}
  end

  describe "for_role/2" do
    test "programmer gets 4 tools", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      names = Enum.map(tools, & &1.name)
      assert length(tools) == 4
      assert "read_file" in names
      assert "write_file" in names
      assert "list_directory" in names
      assert "run_command" in names
    end

    test "test_writer gets 4 tools", %{dir: dir} do
      assert length(Tools.for_role(:test_writer, dir)) == 4
    end

    test "qa_reviewer gets 3 tools (no write_file)", %{dir: dir} do
      tools = Tools.for_role(:qa_reviewer, dir)
      names = Enum.map(tools, & &1.name)
      assert length(tools) == 3
      refute "write_file" in names
    end
  end

  describe "read_file" do
    test "reads an existing file", %{dir: dir} do
      File.write!(Path.join(dir, "hello.txt"), "world")
      [read_tool | _] = Tools.for_role(:programmer, dir)
      assert {:ok, "world"} = ReqLLM.Tool.execute(read_tool, %{path: "hello.txt"})
    end

    test "returns error for missing file", %{dir: dir} do
      [read_tool | _] = Tools.for_role(:programmer, dir)
      assert {:ok, "Error:" <> _} = ReqLLM.Tool.execute(read_tool, %{path: "nope.txt"})
    end

    test "blocks path traversal", %{dir: dir} do
      [read_tool | _] = Tools.for_role(:programmer, dir)
      assert {:error, _} = ReqLLM.Tool.execute(read_tool, %{path: "../../etc/passwd"})
    end
  end

  describe "write_file" do
    test "writes a file and creates directories", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      write_tool = Enum.find(tools, &(&1.name == "write_file"))

      assert {:ok, "Written: lib/foo.ex"} =
               ReqLLM.Tool.execute(write_tool, %{path: "lib/foo.ex", content: "hello"})

      assert File.read!(Path.join(dir, "lib/foo.ex")) == "hello"
    end

    test "blocks path traversal", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      write_tool = Enum.find(tools, &(&1.name == "write_file"))
      assert {:error, _} = ReqLLM.Tool.execute(write_tool, %{path: "../evil.sh", content: "bad"})
    end
  end

  describe "list_directory" do
    test "lists directory contents", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      tools = Tools.for_role(:programmer, dir)
      list_tool = Enum.find(tools, &(&1.name == "list_directory"))
      assert {:ok, listing} = ReqLLM.Tool.execute(list_tool, %{path: "."})
      assert listing =~ "a.txt"
      assert listing =~ "b.txt"
    end

    test "returns error for missing directory", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      list_tool = Enum.find(tools, &(&1.name == "list_directory"))
      assert {:ok, "Error:" <> _} = ReqLLM.Tool.execute(list_tool, %{path: "nope"})
    end
  end

  describe "run_command" do
    test "runs an allowed command", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))
      assert {:ok, output} = ReqLLM.Tool.execute(cmd_tool, %{command: "ls"})
      assert is_binary(output)
    end

    test "rejects disallowed commands", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))
      assert {:error, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "rm -rf /"})
    end

    test "allows commands with env var prefixes", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))
      assert {:ok, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "MIX_ENV=test mix test"})
    end

    test "returns exit code on failure", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))
      assert {:ok, output} = ReqLLM.Tool.execute(cmd_tool, %{command: "ls nonexistent_dir_xyz"})
      assert output =~ "Exit code"
    end
  end

  describe "for_role/3 with options" do
    test "custom allowed_commands restricts run_command", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir, allowed_commands: ~w(echo))
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))

      assert {:ok, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "echo hello"})
      assert {:error, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "ls"})
    end

    test "custom allowed_commands works for qa_reviewer", %{dir: dir} do
      tools = Tools.for_role(:qa_reviewer, dir, allowed_commands: ~w(echo))
      cmd_tool = Enum.find(tools, &(&1.name == "run_command"))

      assert {:ok, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "echo test"})
      assert {:error, _} = ReqLLM.Tool.execute(cmd_tool, %{command: "cat file"})
    end
  end

  describe "default_allowed_commands/0" do
    test "returns the default command list" do
      commands = Tools.default_allowed_commands()
      assert is_list(commands)
      assert "mix" in commands
      assert "elixir" in commands
      assert "cat" in commands
    end
  end

  describe "list_directory path traversal" do
    test "blocks path traversal", %{dir: dir} do
      tools = Tools.for_role(:programmer, dir)
      list_tool = Enum.find(tools, &(&1.name == "list_directory"))
      assert {:error, _} = ReqLLM.Tool.execute(list_tool, %{path: "../../"})
    end
  end

  describe "resolve_path!/2" do
    test "resolves relative paths", %{dir: dir} do
      assert Tools.resolve_path!("lib/foo.ex", dir) == Path.join(dir, "lib/foo.ex")
    end

    test "blocks absolute paths outside working dir", %{dir: dir} do
      assert_raise ArgumentError, ~r/Path traversal/, fn ->
        Tools.resolve_path!("/etc/passwd", dir)
      end
    end

    test "blocks .. traversal", %{dir: dir} do
      assert_raise ArgumentError, ~r/Path traversal/, fn ->
        Tools.resolve_path!("../../../etc/passwd", dir)
      end
    end

    test "resolves current directory", %{dir: dir} do
      assert Tools.resolve_path!(".", dir) == dir
    end
  end
end
