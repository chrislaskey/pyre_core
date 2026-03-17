defmodule Pyre.Flows.IterativeBuildTest do
  use ExUnit.Case, async: false

  alias Pyre.Flows.IterativeBuild

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_ib_test_#{System.unique_integer([:positive])}")
    runs_dir = Path.join(tmp_dir, "priv/pyre/runs")
    File.mkdir_p!(runs_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp with_cwd(dir, fun) do
    original = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end

  test "runs full pipeline to completion", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "# Requirements\n\nProducts page requirements.",
      "# Design\n\nProducts page design.",
      "# Architecture Plan\n\n## Phase 1\n\nSetup schema.",
      "## Branch Name\n\nfeature/products-page\n\n## PR Title\n\nAdd products page\n\n## PR Body\n\nImplements products page.",
      "# Implementation Summary\n\nAll phases complete.",
      "APPROVE\n\nGreat work!"
    ])

    result =
      with_cwd(tmp_dir, fn ->
        IterativeBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.verdict == :approve
    assert state.requirements =~ "Requirements"
    assert state.design =~ "Design"
    assert state.architecture_plan =~ "Architecture Plan"
    assert state.implementation_summary =~ "Implementation Summary"
    assert state.review =~ "APPROVE"
  end

  test "dry run skips LLM calls", %{tmp_dir: tmp_dir} do
    result =
      with_cwd(tmp_dir, fn ->
        IterativeBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          dry_run: true,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
  end

  test "fast mode passes model override in context", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Architecture plan.",
      "## Branch Name\n\nfeature/change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange.",
      "Implementation done.",
      "APPROVE\n\nGood."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        IterativeBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          fast: true,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
  end

  test "propagates error from a failing action", %{tmp_dir: tmp_dir} do
    defmodule FailingLLM do
      @behaviour Pyre.LLM
      def generate(_, _, _ \\ []), do: {:error, :llm_failure}
      def stream(_, _, _ \\ []), do: {:error, :llm_failure}
      def chat(_, _, _, _ \\ []), do: {:error, :llm_failure}
    end

    result =
      with_cwd(tmp_dir, fn ->
        IterativeBuild.run("Build a products page",
          llm: FailingLLM,
          streaming: false,
          project_dir: tmp_dir,
          log_fn: fn _ -> :ok end
        )
      end)

    assert {:error, :llm_failure} = result
  end

  test "review with reject still completes (no rework loop)", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Architecture plan.",
      "## Branch Name\n\nfeature/change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange.",
      "Implementation done.",
      "REJECT\n\nNeeds more test coverage."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        IterativeBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.verdict == :reject
  end

  test "log_fn receives stage messages", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Architecture plan.",
      "## Branch Name\n\nfeature/change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange.",
      "Implementation done.",
      "APPROVE\n\nGood."
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    with_cwd(tmp_dir, fn ->
      IterativeBuild.run("Build a products page",
        llm: Pyre.LLM.Mock,
        streaming: false,
        project_dir: tmp_dir,
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )
    end)

    log_messages = Agent.get(logs, & &1)
    assert Enum.any?(log_messages, &(&1 =~ "Run directory:"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: product_manager"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: software_architect"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: branch_setup"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: software_engineer"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: pr_reviewer"))
    assert Enum.any?(log_messages, &(&1 =~ "APPROVED"))

    Agent.stop(logs)
  end
end
