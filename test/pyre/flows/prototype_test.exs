defmodule Pyre.Flows.PrototypeTest do
  use ExUnit.Case, async: false

  alias Pyre.Flows.Prototype

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pyre_proto_test_#{System.unique_integer([:positive])}")

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

  test "runs to completion with single mock response", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "### What Was Built\n- Products listing page prototype"
    ])

    result =
      with_cwd(tmp_dir, fn ->
        Prototype.run("Build a products listing page",
          llm: Pyre.LLM.Mock,
          streaming: false,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
    assert state.prototype_output =~ "What Was Built"
  end

  test "dry run skips LLM calls", %{tmp_dir: tmp_dir} do
    result =
      with_cwd(tmp_dir, fn ->
        Prototype.run("Build a prototype",
          llm: Pyre.LLM.Mock,
          streaming: false,
          dry_run: true,
          project_dir: tmp_dir
        )
      end)

    assert {:ok, state} = result
    assert state.phase == :complete
  end

  test "propagates error from a failing LLM", %{tmp_dir: tmp_dir} do
    defmodule FailingLLM do
      @behaviour Pyre.LLM
      def generate(_, _, _ \\ []), do: {:error, :llm_failure}
      def stream(_, _, _ \\ []), do: {:error, :llm_failure}
      def chat(_, _, _, _ \\ []), do: {:error, :llm_failure}
    end

    result =
      with_cwd(tmp_dir, fn ->
        Prototype.run("Build a prototype",
          llm: FailingLLM,
          streaming: false,
          project_dir: tmp_dir,
          log_fn: fn _ -> :ok end
        )
      end)

    assert {:error, :llm_failure} = result
  end

  test "default_interactive_stages/0 returns [:prototyping]" do
    assert Prototype.default_interactive_stages() == [:prototyping]
  end

  test "log_fn receives stage messages", %{tmp_dir: tmp_dir} do
    Process.put(:mock_llm_responses, [
      "Prototype completed."
    ])

    logs = Agent.start_link(fn -> [] end) |> elem(1)

    with_cwd(tmp_dir, fn ->
      Prototype.run("Build a prototype",
        llm: Pyre.LLM.Mock,
        streaming: false,
        project_dir: tmp_dir,
        log_fn: fn msg -> Agent.update(logs, &(&1 ++ [msg])) end
      )
    end)

    log_messages = Agent.get(logs, & &1)
    assert Enum.any?(log_messages, &(&1 =~ "Run directory:"))
    assert Enum.any?(log_messages, &(&1 =~ "Stage: prototype_engineer"))

    Agent.stop(logs)
  end
end
