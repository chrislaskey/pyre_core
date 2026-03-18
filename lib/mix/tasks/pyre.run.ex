defmodule Mix.Tasks.Pyre.Run do
  @moduledoc """
  Runs the multi-agent pipeline to build a Phoenix feature.

  Six specialized LLM agents (Product Manager, Designer, Programmer,
  Test Writer, Code Reviewer, Shipper) collaborate serially to implement
  the feature, then ship it as a GitHub pull request.

  ## Usage

      mix pyre.run "Build a products listing page"

  ## Options

    * `--fast` -- Use the fastest (haiku) model for all agents
    * `--dry-run` -- Print plan without executing LLM calls
    * `--verbose` -- Print diagnostic information
    * `--project-dir` -- Working directory for the agents (default: `.`)
    * `--no-stream` -- Disable streaming output
    * `--attach` / `-a` -- Attach a file to the prompt (repeatable)
    * `--feature` / `-n` -- Feature name to group related runs (optional)

  ## Attachments

  You can attach files (mockups, specs, data) that all agents will see:

      mix pyre.run "Build a products page" --attach mockup.png --attach spec.md

  ## Output

  Artifacts are written to `priv/pyre/features/<feature>/<timestamp>/`:
    - `00_feature.md` -- Original feature request
    - `01_requirements.md` -- Product Manager output
    - `02_design_spec.md` -- Designer output
    - `03_implementation_summary.md` -- Programmer output
    - `04_test_summary.md` -- Test Writer output
    - `05_review_verdict.md` -- Code Reviewer verdict (APPROVE/REJECT)
    - `06_shipping_summary.md` -- Shipper output (branch, commit, PR URL)
  """
  @shortdoc "Runs multi-agent pipeline to build a Phoenix feature"

  use Mix.Task

  @switches [
    fast: :boolean,
    dry_run: :boolean,
    verbose: :boolean,
    project_dir: :string,
    no_stream: :boolean,
    attach: :keep,
    feature: :string
  ]
  @aliases [f: :fast, d: :dry_run, v: :verbose, p: :project_dir, a: :attach, n: :feature]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    feature_description =
      case args do
        [desc | _] ->
          desc

        [] ->
          Mix.raise("""
          Usage: mix pyre.run "feature description"

          Example: mix pyre.run "Build a products listing page"
          """)
      end

    attachments = load_attachments(Keyword.get_values(opts, :attach))

    flow_opts = [
      fast: Keyword.get(opts, :fast, false),
      dry_run: Keyword.get(opts, :dry_run, false),
      verbose: Keyword.get(opts, :verbose, false),
      project_dir: Keyword.get(opts, :project_dir, "."),
      streaming: !Keyword.get(opts, :no_stream, false),
      log_fn: fn msg -> Mix.shell().info(msg) end,
      attachments: attachments,
      feature: Keyword.get(opts, :feature)
    ]

    case Pyre.Flows.FeatureBuild.run(feature_description, flow_opts) do
      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Mix.raise("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp load_attachments(paths) do
    Enum.map(paths, fn path ->
      unless File.exists?(path) do
        Mix.raise("Attachment not found: #{path}")
      end

      %{
        filename: Path.basename(path),
        content: File.read!(path),
        media_type: Pyre.Plugins.Artifact.media_type_from_filename(path)
      }
    end)
  end
end
