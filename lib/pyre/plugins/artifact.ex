defmodule Pyre.Plugins.Artifact do
  @moduledoc """
  Filesystem operations for agent run artifacts.

  Manages timestamped run directories and versioned Markdown artifact files.
  """

  @doc """
  Creates a timestamped run directory under `base_path`.

  Returns `{:ok, run_dir}` where `run_dir` is the full path to the created directory.
  """
  @spec create_run_dir(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_run_dir(base_path) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    run_dir = Path.join(base_path, timestamp)

    case File.mkdir_p(run_dir) do
      :ok -> {:ok, run_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes content to a file in the run directory.

  Appends `.md` extension if the filename doesn't already have one.
  """
  @spec write(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write(run_dir, filename, content) do
    filename = ensure_md_extension(filename)
    path = Path.join(run_dir, filename)
    File.write(path, content)
  end

  @doc """
  Reads a file from the run directory.

  Appends `.md` extension if the filename doesn't already have one.
  """
  @spec read(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(run_dir, filename) do
    filename = ensure_md_extension(filename)
    path = Path.join(run_dir, filename)
    File.read(path)
  end

  @doc """
  Finds the latest version of an artifact by base name.

  Given a base name like `"03_implementation_summary"`, finds the highest versioned
  file (e.g., `03_implementation_summary_v3.md` > `03_implementation_summary_v2.md`).

  Returns `{:ok, filename, content}` or `{:error, :not_found}`.
  """
  @spec latest(String.t(), String.t()) :: {:ok, String.t(), String.t()} | {:error, :not_found}
  def latest(run_dir, base_name) do
    base_name = String.replace_trailing(base_name, ".md", "")
    pattern = Path.join(run_dir, "#{base_name}*.md")

    case Path.wildcard(pattern) |> Enum.sort() |> List.last() do
      nil ->
        {:error, :not_found}

      path ->
        filename = Path.basename(path)

        case File.read(path) do
          {:ok, content} -> {:ok, filename, content}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Assembles multiple artifact files into a single concatenated string.

  Each artifact is preceded by a `## filename` header and separated by `---`.
  Resolves each filename to its latest version.
  """
  @spec assemble(String.t(), [String.t()]) :: {:ok, String.t()}
  def assemble(_run_dir, []), do: {:ok, ""}

  def assemble(run_dir, filenames) do
    sections =
      filenames
      |> Enum.map(fn filename ->
        base_name = String.replace_trailing(filename, ".md", "")

        case latest(run_dir, base_name) do
          {:ok, resolved_filename, content} ->
            "## #{resolved_filename}\n\n#{content}"

          {:error, :not_found} ->
            "## #{filename}\n\n(not found)"
        end
      end)

    {:ok, Enum.join(sections, "\n\n---\n\n")}
  end

  @doc """
  Returns a versioned artifact name.

  Cycle 1 returns the base name unchanged. Cycle 2+ appends `_vN`.
  """
  @spec versioned_name(String.t(), pos_integer()) :: String.t()
  def versioned_name(base_name, 1), do: base_name
  def versioned_name(base_name, cycle) when cycle > 1, do: "#{base_name}_v#{cycle}"

  defp ensure_md_extension(filename) do
    if String.ends_with?(filename, ".md"), do: filename, else: "#{filename}.md"
  end
end
