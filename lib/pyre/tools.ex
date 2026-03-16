defmodule Pyre.Tools do
  @max_output_bytes 10_000

  @default_allowed_commands [
    "MIX_ENV=test mix",
    "mix",
    "elixir",
    "git",
    "cat",
    "ls",
    "grep",
    "find",
    "head",
    "tail",
    "wc",
    "mkdir"
  ]

  @moduledoc """
  Tool definitions for LLM agent actions.

  Provides file system and shell tools that agents use to read, write,
  and execute commands in the target project directory. Tools are sandboxed
  to the working directory (and any additional allowed paths) via path validation.

  ## Configuration

  The allowed commands for `run_command` can be customized per role:

      Pyre.Tools.for_role(:programmer, "/path/to/project",
        allowed_commands: ~w(mix elixir ls grep git)
      )

  Additional directories can be made accessible via `:allowed_paths`:

      Pyre.Tools.for_role(:programmer, "/path/to/project",
        allowed_paths: ["/path/to/other/app"]
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
    * `:allowed_paths` — Additional absolute directory paths that file tools
      can read and write. Useful for monorepos where agents need access to
      sibling apps.

  ## Examples

      Pyre.Tools.for_role(:programmer, "/path/to/project")
      Pyre.Tools.for_role(:programmer, "/path/to/project", allowed_commands: ~w(mix elixir ls))
      Pyre.Tools.for_role(:programmer, "/path/to/project", allowed_paths: ["/path/to/other/app"])
      Pyre.Tools.for_role(:qa_reviewer, "/path/to/project")
  """
  def for_role(role, working_dir, opts \\ [])

  def for_role(:programmer, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:test_writer, working_dir, opts), do: all_tools(working_dir, opts)

  def for_role(:qa_reviewer, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:designer, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:product_manager, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:shipper, working_dir, opts), do: read_only_tools(working_dir, opts)

  defp read_only_tools(working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)
    base_paths = build_base_paths(working_dir, opts)

    [
      read_file_tool(base_paths),
      list_directory_tool(base_paths),
      run_command_tool(working_dir, allowed)
    ]
  end

  defp all_tools(working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)
    base_paths = build_base_paths(working_dir, opts)

    [
      read_file_tool(base_paths),
      write_file_tool(base_paths),
      list_directory_tool(base_paths),
      run_command_tool(working_dir, allowed)
    ]
  end

  defp build_base_paths(working_dir, opts) do
    extra = Keyword.get(opts, :allowed_paths, [])
    expanded_wd = Path.expand(working_dir)
    [expanded_wd | Enum.map(extra, &Path.expand(&1, expanded_wd))]
  end

  defp paths_description(base_paths) do
    case base_paths do
      [single] ->
        "Project root: #{single}. Relative paths resolve from project root."

      [primary | extra] ->
        dirs = Enum.join(extra, ", ")

        "Project root: #{primary}. Additional accessible directories: #{dirs}. " <>
          "Use absolute paths to access files outside the project root."
    end
  end

  # --- Tool Definitions ---

  defp read_file_tool(base_paths) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description:
        "Read the contents of a file. Path can be absolute or relative to the project root. #{paths_description(base_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "File path (absolute or relative to project root)"
        ]
      ],
      callback: fn %{path: path} ->
        full_path = resolve_path!(path, base_paths)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp write_file_tool(base_paths) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Write content to a file. Path can be absolute or relative to the project root. Creates parent directories if needed. #{paths_description(base_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "File path (absolute or relative to project root)"
        ],
        content: [type: :string, required: true, doc: "Complete file content to write"]
      ],
      callback: fn %{path: path, content: content} ->
        full_path = resolve_path!(path, base_paths)
        File.mkdir_p!(Path.dirname(full_path))

        case File.write(full_path, content) do
          :ok -> {:ok, "Written: #{path}"}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp list_directory_tool(base_paths) do
    ReqLLM.Tool.new!(
      name: "list_directory",
      description:
        "List files and directories at the given path. Set recursive to true to list the full directory tree (directories shown with trailing /). #{paths_description(base_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Directory path (absolute or relative to project root)"
        ],
        recursive: [
          type: :boolean,
          required: false,
          doc: "List directory tree recursively. Default: false"
        ]
      ],
      callback: fn params ->
        full_path = resolve_path!(params.path, base_paths)
        recursive? = Map.get(params, :recursive, false)

        if recursive? do
          list_recursive(full_path, full_path)
        else
          case File.ls(full_path) do
            {:ok, entries} -> {:ok, entries |> Enum.sort() |> Enum.join("\n")}
            {:error, reason} -> {:ok, "Error: #{reason}"}
          end
        end
      end
    )
  end

  defp list_recursive(dir, base) do
    case File.ls(dir) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn entry ->
            full = Path.join(dir, entry)
            relative = Path.relative_to(full, base)

            if File.dir?(full) do
              case list_recursive(full, base) do
                {:ok, ""} -> [relative <> "/"]
                {:ok, children} -> [relative <> "/" | String.split(children, "\n")]
              end
            else
              [relative]
            end
          end)

        {:ok, truncate(Enum.join(lines, "\n"))}

      {:error, reason} ->
        {:ok, "Error: #{reason}"}
    end
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
  def resolve_path!(relative_path, base_paths) when is_list(base_paths) do
    primary = hd(base_paths)
    full_path = Path.expand(relative_path, primary)

    allowed? =
      Enum.any?(base_paths, fn base ->
        expanded = Path.expand(base)
        full_path == expanded or String.starts_with?(full_path, expanded <> "/")
      end)

    unless allowed? do
      raise ArgumentError, "Path traversal blocked: #{relative_path}"
    end

    full_path
  end

  def resolve_path!(relative_path, working_dir) when is_binary(working_dir) do
    resolve_path!(relative_path, [working_dir])
  end

  defp validate_command!(command, allowed_commands) do
    trimmed = String.trim(command)

    allowed? =
      Enum.any?(allowed_commands, fn prefix ->
        trimmed == prefix or String.starts_with?(trimmed, prefix <> " ")
      end)

    unless allowed? do
      raise ArgumentError,
            "Command not allowed: #{trimmed}. Allowed: #{Enum.join(allowed_commands, ", ")}"
    end
  end

  defp truncate(text) when byte_size(text) > @max_output_bytes do
    String.slice(text, 0, @max_output_bytes) <> "\n...(truncated)"
  end

  defp truncate(text), do: text
end
