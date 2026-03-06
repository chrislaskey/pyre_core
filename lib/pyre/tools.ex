defmodule Pyre.Tools do
  @max_output_bytes 10_000
  @default_allowed_commands ~w(mix elixir cat ls grep find head tail wc mkdir)

  @moduledoc """
  Tool definitions for LLM agent actions.

  Provides file system and shell tools that agents use to read, write,
  and execute commands in the target project directory. Tools are sandboxed
  to the working directory via path validation.

  ## Configuration

  The allowed commands for `run_command` can be customized per role:

      Pyre.Tools.for_role(:programmer, "/path/to/project",
        allowed_commands: ~w(mix elixir ls grep git)
      )

  Default allowed commands: #{inspect(@default_allowed_commands)}
  """

  @doc """
  Returns the default allowed commands list.
  """
  def default_allowed_commands, do: @default_allowed_commands

  @doc """
  Returns tools for a given agent role, scoped to the working directory.

  ## Options

    * `:allowed_commands` — List of command prefixes the `run_command` tool
      will accept. Defaults to `#{inspect(@default_allowed_commands)}`.

  ## Examples

      Pyre.Tools.for_role(:programmer, "/path/to/project")
      Pyre.Tools.for_role(:programmer, "/path/to/project", allowed_commands: ~w(mix elixir ls))
      Pyre.Tools.for_role(:qa_reviewer, "/path/to/project")
  """
  def for_role(role, working_dir, opts \\ [])

  def for_role(:programmer, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:test_writer, working_dir, opts), do: all_tools(working_dir, opts)

  def for_role(:qa_reviewer, working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)

    [
      read_file_tool(working_dir),
      list_directory_tool(working_dir),
      run_command_tool(working_dir, allowed)
    ]
  end

  defp all_tools(working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)

    [
      read_file_tool(working_dir),
      write_file_tool(working_dir),
      list_directory_tool(working_dir),
      run_command_tool(working_dir, allowed)
    ]
  end

  # --- Tool Definitions ---

  defp read_file_tool(working_dir) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description: "Read the contents of a file. Path is relative to the project root.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "File path relative to the project root"]
      ],
      callback: fn %{path: path} ->
        full_path = resolve_path!(path, working_dir)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp write_file_tool(working_dir) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Write content to a file. Path is relative to the project root. Creates parent directories if needed.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "File path relative to the project root"],
        content: [type: :string, required: true, doc: "Complete file content to write"]
      ],
      callback: fn %{path: path, content: content} ->
        full_path = resolve_path!(path, working_dir)
        File.mkdir_p!(Path.dirname(full_path))

        case File.write(full_path, content) do
          :ok -> {:ok, "Written: #{path}"}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp list_directory_tool(working_dir) do
    ReqLLM.Tool.new!(
      name: "list_directory",
      description:
        "List files and directories at the given path. Path is relative to the project root.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Directory path relative to the project root"]
      ],
      callback: fn %{path: path} ->
        full_path = resolve_path!(path, working_dir)

        case File.ls(full_path) do
          {:ok, entries} -> {:ok, entries |> Enum.sort() |> Enum.join("\n")}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp run_command_tool(working_dir, allowed_commands) do
    ReqLLM.Tool.new!(
      name: "run_command",
      description:
        "Run a shell command in the project directory. Allowed commands: #{Enum.join(allowed_commands, ", ")}.",
      parameter_schema: [
        command: [type: :string, required: true, doc: "Shell command to execute"]
      ],
      callback: fn %{command: command} ->
        validate_command!(command, allowed_commands)

        {output, code} =
          System.cmd("sh", ["-c", command],
            cd: working_dir,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "dev"}]
          )

        result =
          if code == 0 do
            truncate(output)
          else
            "Exit code #{code}:\n#{truncate(output)}"
          end

        {:ok, result}
      end
    )
  end

  # --- Safety ---

  @doc false
  def resolve_path!(relative_path, working_dir) do
    full_path = Path.expand(relative_path, working_dir)
    expanded_wd = Path.expand(working_dir)

    unless String.starts_with?(full_path, expanded_wd <> "/") or full_path == expanded_wd do
      raise ArgumentError, "Path traversal blocked: #{relative_path}"
    end

    full_path
  end

  defp validate_command!(command, allowed_commands) do
    first_word =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first("")

    unless first_word in allowed_commands do
      raise ArgumentError,
            "Command not allowed: #{first_word}. Allowed: #{Enum.join(allowed_commands, ", ")}"
    end
  end

  defp truncate(text) when byte_size(text) > @max_output_bytes do
    String.slice(text, 0, @max_output_bytes) <> "\n...(truncated)"
  end

  defp truncate(text), do: text
end
