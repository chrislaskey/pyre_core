defmodule Pyre.Plugins.Persona do
  @moduledoc """
  Loads persona Markdown files and builds LLM message structures.

  Personas are loaded from the consuming project's `priv/pyre/personas/`
  directory, with fallback to the library's built-in personas.
  """

  @doc """
  Loads a persona Markdown file by name.

  The name should be an atom matching the filename without extension
  (e.g., `:product_manager` loads `product_manager.md`).
  """
  @spec load(atom()) :: {:ok, String.t()} | {:error, term()}
  def load(persona_name) do
    path = Path.join(personas_dir(), "#{persona_name}.md")
    File.read(path)
  end

  @doc """
  Returns a system message map for the given persona.
  """
  @spec system_message(atom()) :: {:ok, map()} | {:error, term()}
  def system_message(persona_name) do
    case load(persona_name) do
      {:ok, content} -> {:ok, %{role: :system, content: content}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Builds a user message map for an agent stage.

  Assembles the feature description, any prompt attachments, any artifacts
  from prior stages, and output instructions telling the agent where to
  write its artifact.

  When image attachments are present, returns multipart content (a list of
  content parts) instead of a plain string.
  """
  @spec user_message(String.t(), String.t(), String.t(), String.t(), [map()]) :: map()
  def user_message(
        feature_description,
        artifacts_content,
        run_dir,
        artifact_filename,
        attachments \\ []
      ) do
    alias Pyre.Plugins.Artifact

    text_attachments = Enum.filter(attachments, &Artifact.text_attachment?/1)
    image_attachments = Enum.filter(attachments, &Artifact.image_attachment?/1)

    sections = ["## Feature Request\n\n#{feature_description}"]

    sections =
      if text_attachments != [] do
        attachment_sections =
          Enum.map(text_attachments, fn att ->
            "### #{att.filename}\n\n#{att.content}"
          end)

        sections ++ ["## Prompt Attachments\n\n#{Enum.join(attachment_sections, "\n\n")}"]
      else
        sections
      end

    sections =
      if artifacts_content != "" do
        sections ++ ["## Prior Artifacts\n\n#{artifacts_content}"]
      else
        sections
      end

    output_path = Path.join(run_dir, artifact_filename)

    sections =
      sections ++
        [
          "## Output Instructions\n\nAfter completing your work, write a summary to: `#{output_path}`\n\nThe summary should be a Markdown document following the format specified in your persona instructions."
        ]

    text_body = Enum.join(sections, "\n\n")

    alias ReqLLM.Message.ContentPart

    if image_attachments == [] do
      %{role: :user, content: text_body}
    else
      image_parts =
        Enum.map(image_attachments, fn att ->
          ContentPart.image(att.content, att.media_type)
        end)

      %{role: :user, content: [ContentPart.text(text_body) | image_parts]}
    end
  end

  defp personas_dir do
    project_dir = Path.join(File.cwd!(), "priv/pyre/personas")

    if File.dir?(project_dir) do
      project_dir
    else
      Application.app_dir(:pyre, "priv/pyre/personas")
    end
  end
end
