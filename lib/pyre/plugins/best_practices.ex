defmodule Pyre.Plugins.BestPractices do
  @moduledoc """
  Loads best practices Markdown files for use as fallback text when stages are skipped.

  Best practices are loaded from the consuming project's `priv/pyre/best_practices/`
  directory, with fallback to the library's built-in defaults. This follows the same
  pattern as `Pyre.Plugins.Persona`.
  """

  @doc """
  Loads a best practices Markdown file by role name.

  The name should be an atom matching the filename without extension
  (e.g., `:designer` loads `designer.md`).
  """
  @spec load(atom()) :: {:ok, String.t()} | {:error, term()}
  def load(role_name) do
    path = Path.join(best_practices_dir(), "#{role_name}.md")
    File.read(path)
  end

  @doc """
  Returns the best practices text for a role, with a generic fallback
  if no file is found.
  """
  @spec fallback_text(atom()) :: String.t()
  def fallback_text(role_name) do
    case load(role_name) do
      {:ok, content} -> content
      {:error, _} -> "No specific guidelines provided. Use general best practices."
    end
  end

  defp best_practices_dir do
    project_dir = Path.join(File.cwd!(), "priv/pyre/best_practices")

    if File.dir?(project_dir) do
      project_dir
    else
      Application.app_dir(:pyre, "priv/pyre/best_practices")
    end
  end
end
