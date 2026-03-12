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

  @doc """
  Stores attachment files in the `prompt/` subdirectory of a run directory.

  Each attachment is a map with `:filename` and `:content` keys.
  Returns `:ok` or `{:error, term()}`.
  """
  @spec store_attachments(String.t(), [map()]) :: :ok | {:error, term()}
  def store_attachments(_run_dir, []), do: :ok

  def store_attachments(run_dir, attachments) do
    prompt_dir = Path.join(run_dir, "prompt")

    with :ok <- File.mkdir_p(prompt_dir) do
      Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
        path = Path.join(prompt_dir, attachment.filename)

        case File.write(path, attachment.content) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Reads all attachment files from the `prompt/` subdirectory of a run directory.

  Returns a list of attachment maps with `:filename`, `:content`, and `:media_type` keys.
  """
  @spec read_attachments(String.t()) :: [map()]
  def read_attachments(run_dir) do
    prompt_dir = Path.join(run_dir, "prompt")

    case File.ls(prompt_dir) do
      {:ok, filenames} ->
        filenames
        |> Enum.sort()
        |> Enum.flat_map(fn filename ->
          path = Path.join(prompt_dir, filename)

          case File.read(path) do
            {:ok, content} ->
              [
                %{
                  filename: filename,
                  content: content,
                  media_type: media_type_from_filename(filename)
                }
              ]

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns `true` if the attachment has a text-based media type.
  """
  @spec text_attachment?(map()) :: boolean()
  def text_attachment?(%{media_type: "text/" <> _}), do: true
  def text_attachment?(%{media_type: "application/json"}), do: true
  def text_attachment?(_), do: false

  @doc """
  Returns `true` if the attachment has an image media type.
  """
  @spec image_attachment?(map()) :: boolean()
  def image_attachment?(%{media_type: "image/" <> _}), do: true
  def image_attachment?(_), do: false

  @doc """
  Maps a filename extension to a MIME media type.
  """
  @spec media_type_from_filename(String.t()) :: String.t()
  def media_type_from_filename(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> extension_to_media_type()
  end

  @extension_map %{
    ".md" => "text/markdown",
    ".txt" => "text/plain",
    ".csv" => "text/csv",
    ".html" => "text/html",
    ".css" => "text/css",
    ".js" => "text/javascript",
    ".ts" => "text/javascript",
    ".ex" => "text/x-elixir",
    ".exs" => "text/x-elixir",
    ".json" => "application/json",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  defp extension_to_media_type(ext) do
    Map.get(@extension_map, ext, "application/octet-stream")
  end

  defp ensure_md_extension(filename) do
    if String.ends_with?(filename, ".md"), do: filename, else: "#{filename}.md"
  end
end
