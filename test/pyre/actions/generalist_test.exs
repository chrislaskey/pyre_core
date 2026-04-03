defmodule Pyre.Actions.GeneralistTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.Generalist
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_gen_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir, tmp_dir: tmp_dir}
  end

  test "generates output and writes artifact", %{run_dir: run_dir, tmp_dir: tmp_dir} do
    Process.put(:mock_llm_response, "# Summary\n\nHere's what I did.")

    params = %{feature_description: "Help me debug this issue", run_dir: run_dir}

    context = %{
      llm: Pyre.LLM.Mock,
      streaming: false,
      working_dir: tmp_dir,
      allowed_paths: [tmp_dir]
    }

    assert {:ok, result} = Generalist.run(params, context)
    assert result.generalist_output =~ "Summary"
    assert {:ok, content} = Artifact.read(run_dir, "01_generalist_output")
    assert content =~ "Summary"
  end

  test "returns error when LLM fails", %{run_dir: run_dir, tmp_dir: tmp_dir} do
    defmodule FailingLLM do
      @behaviour Pyre.LLM
      def generate(_, _, _ \\ []), do: {:error, :api_error}
      def stream(_, _, _ \\ []), do: {:error, :api_error}
      def chat(_, _, _, _ \\ []), do: {:error, :api_error}
    end

    params = %{feature_description: "Help me debug this issue", run_dir: run_dir}
    context = %{llm: FailingLLM, streaming: false, working_dir: tmp_dir, allowed_paths: [tmp_dir]}

    assert {:error, :api_error} = Generalist.run(params, context)
  end
end
