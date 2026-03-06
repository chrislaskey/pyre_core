defmodule Mix.Tasks.Pyre.Install do
  @moduledoc """
  Installs Pyre into a Phoenix project.

  Copies default persona files and creates the runs directory so the
  multi-agent pipeline can operate in the consuming project.

  ## Usage

      mix pyre.install

  ## What it does

    * Copies built-in persona `.md` files to `priv/pyre/personas/`
    * Creates `priv/pyre/runs/.gitkeep`
    * Adds `.gitignore` entries for `priv/pyre/runs/*`

  Files that already exist are not overwritten, so local customizations
  to personas are preserved.
  """
  @shortdoc "Installs Pyre persona files and run directory"

  use Igniter.Mix.Task

  @personas ~w(product_manager designer programmer test_writer code_reviewer)

  @gitignore_entries """

  # Pyre agent run output
  /priv/pyre/runs/*
  !/priv/pyre/runs/.gitkeep
  """

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      example: "mix pyre.install"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    source_dir = Application.app_dir(:pyre, "priv/pyre/personas")

    igniter =
      Enum.reduce(@personas, igniter, fn persona, acc ->
        source = Path.join(source_dir, "#{persona}.md")
        dest = "priv/pyre/personas/#{persona}.md"

        Igniter.create_new_file(acc, dest, File.read!(source), on_exists: :skip)
      end)

    igniter
    |> Igniter.create_new_file("priv/pyre/runs/.gitkeep", "", on_exists: :skip)
    |> append_gitignore()
  end

  defp append_gitignore(igniter) do
    Igniter.create_or_update_file(
      igniter,
      ".gitignore",
      String.trim(@gitignore_entries),
      fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, "/priv/pyre/runs/*") do
          source
        else
          Rewrite.Source.update(source, :content, content <> @gitignore_entries)
        end
      end
    )
  end
end
