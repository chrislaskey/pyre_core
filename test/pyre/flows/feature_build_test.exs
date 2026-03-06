defmodule Pyre.Flows.FeatureBuildTest do
  use ExUnit.Case, async: false

  alias Pyre.Flows.FeatureBuild

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_flow_test_#{System.unique_integer([:positive])}")
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

  test "runs full pipeline with approval on first cycle", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "# Requirements\n\nProducts page requirements.",
      "# Design\n\nProducts page design.",
      "# Implementation\n\nImplemented the feature.",
      "# Tests\n\nAll tests pass.",
      "APPROVE\n\nGreat work!"
    ])

    result =
      with_cwd(tmp_dir, fn ->
        FeatureBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.verdict == :approve
    assert state.review_cycle == 1
    assert state.requirements =~ "Requirements"
    assert state.design =~ "Design"
    assert state.implementation =~ "Implementation"
    assert state.tests =~ "Tests"
  end

  test "review loop retries on reject then approves", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      # Cycle 1: PM, Designer, Programmer, TestWriter, Reviewer (REJECT)
      "# Requirements\n\nRequirements.",
      "# Design\n\nDesign.",
      "# Implementation\n\nFirst attempt.",
      "# Tests\n\nFirst tests.",
      "REJECT\n\nNeeds more test coverage.",
      # Cycle 2: Programmer, TestWriter, Reviewer (APPROVE)
      "# Implementation v2\n\nFixed implementation.",
      "# Tests v2\n\nImproved tests.",
      "APPROVE\n\nLooks good now."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        FeatureBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.verdict == :approve
    assert state.review_cycle == 2
  end

  test "stops at max review cycles", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      # Cycle 1
      "Requirements.",
      "Design.",
      "Impl 1.",
      "Tests 1.",
      "REJECT\n\nBad.",
      # Cycle 2
      "Impl 2.",
      "Tests 2.",
      "REJECT\n\nStill bad.",
      # Cycle 3
      "Impl 3.",
      "Tests 3.",
      "REJECT\n\nStill not great."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        FeatureBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.verdict == :reject
    assert state.review_cycle == 3
  end

  test "fast mode passes model override in context", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood."
    ])

    # Fast mode sets model_override in context. We verify it completes
    # successfully (actions receive the override via context.model_override).
    result =
      with_cwd(tmp_dir, fn ->
        FeatureBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          fast: true,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
  end

  test "dry run skips LLM calls", %{tmp_dir: tmp_dir} do
    result =
      with_cwd(tmp_dir, fn ->
        FeatureBuild.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          dry_run: true,
          project_dir: tmp_dir
        )
      end)

    # Dry run completes but with nil state values since no LLM was called.
    # The flow returns ok because run_action returns {:ok, %{}} in dry_run mode.
    assert {:ok, state} = result
    assert state.phase == :complete
  end
end
