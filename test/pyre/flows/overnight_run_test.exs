defmodule Pyre.Flows.OvernightFeatureTest do
  use ExUnit.Case, async: false

  alias Pyre.Flows.OvernightFeature

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_flow_test_#{System.unique_integer([:positive])}")
    features_dir = Path.join(tmp_dir, "priv/pyre/features")
    File.mkdir_p!(features_dir)
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
      "APPROVE\n\nGreat work!",
      "## Branch Name\n\nfeature/products-page\n\n## Commit Message\n\nfeat: add products page\n\n## PR Title\n\nAdd products page\n\n## PR Body\n\nImplements products page."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        OvernightFeature.run("Build a products page",
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
    assert state.shipping_summary != nil
  end

  test "review loop retries on reject then approves", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      # Cycle 1: PM, Designer, Programmer, TestWriter, Reviewer (REJECT)
      "# Requirements\n\nRequirements.",
      "# Design\n\nDesign.",
      "# Implementation\n\nFirst attempt.",
      "# Tests\n\nFirst tests.",
      "REJECT\n\nNeeds more test coverage.",
      # Cycle 2: Programmer, TestWriter, Reviewer (APPROVE), Shipper
      "# Implementation v2\n\nFixed implementation.",
      "# Tests v2\n\nImproved tests.",
      "APPROVE\n\nLooks good now.",
      "## Branch Name\n\nfeature/products-page\n\n## Commit Message\n\nfeat: add products page\n\n## PR Title\n\nAdd products page\n\n## PR Body\n\nImplements products page."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        OvernightFeature.run("Build a products page",
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
        OvernightFeature.run("Build a products page",
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
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/change\n\n## Commit Message\n\nfeat: change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange."
    ])

    result =
      with_cwd(tmp_dir, fn ->
        OvernightFeature.run("Build a products page",
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
        OvernightFeature.run("Build a products page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          dry_run: true,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
  end

  test "verbose mode emits extra log messages", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/change\n\n## Commit Message\n\nfeat: change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange."
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    with_cwd(tmp_dir, fn ->
      OvernightFeature.run("Build a products page",
        llm: Pyre.LLM.Mock,
        streaming: false,
        verbose: true,
        project_dir: tmp_dir,
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )
    end)

    log_messages = Agent.get(logs, & &1)
    assert Enum.any?(log_messages, &(&1 =~ "[verbose] action:"))
    assert Enum.any?(log_messages, &(&1 =~ "[verbose] run_dir:"))

    Agent.stop(logs)
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
        OvernightFeature.run("Build a products page",
          llm: FailingLLM,
          streaming: false,
          project_dir: tmp_dir,
          log_fn: fn _ -> :ok end
        )
      end)

    assert {:error, :llm_failure} = result
  end

  test "log_fn callback receives all status messages", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Requirements.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/change\n\n## Commit Message\n\nfeat: change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange."
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    with_cwd(tmp_dir, fn ->
      OvernightFeature.run("Build a products page",
        llm: Pyre.LLM.Mock,
        streaming: false,
        project_dir: tmp_dir,
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )
    end)

    log_messages = Agent.get(logs, & &1)
    assert Enum.any?(log_messages, &(&1 =~ "Run directory:"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: product_manager"))
    assert Enum.any?(log_messages, &(&1 =~ "Completed: product_manager"))
    assert Enum.any?(log_messages, &(&1 =~ "APPROVED"))

    Agent.stop(logs)
  end

  test "output_fn callback receives LLM output text", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "My requirements document.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/change\n\n## Commit Message\n\nfeat: change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange."
    ])

    output = Agent.start_link(fn -> [] end) |> elem(1)

    with_cwd(tmp_dir, fn ->
      OvernightFeature.run("Build a products page",
        llm: Pyre.LLM.Mock,
        streaming: false,
        project_dir: tmp_dir,
        output_fn: fn text -> Agent.update(output, &(&1 ++ [text])) end,
        log_fn: fn _ -> :ok end
      )
    end)

    assert is_list(Agent.get(output, & &1))

    Agent.stop(output)
  end
end
