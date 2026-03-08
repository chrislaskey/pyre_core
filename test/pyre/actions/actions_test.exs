defmodule Pyre.Actions.ProductManagerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.ProductManager
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_pm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates requirements and writes artifact", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Requirements\n\nProducts page requirements.")

    params = %{feature_description: "Build a products page", run_dir: run_dir}
    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = ProductManager.run(params, context)
    assert result.requirements =~ "Requirements"
    assert {:ok, content} = Artifact.read(run_dir, "01_requirements")
    assert content =~ "Requirements"
  end

  test "returns error when LLM fails", %{run_dir: run_dir} do
    defmodule FailingLLM do
      @behaviour Pyre.LLM
      def generate(_, _, _ \\ []), do: {:error, :api_error}
      def stream(_, _, _ \\ []), do: {:error, :api_error}
      def chat(_, _, _, _ \\ []), do: {:error, :api_error}
    end

    params = %{feature_description: "Build a products page", run_dir: run_dir}
    context = %{llm: FailingLLM, streaming: false}

    assert {:error, :api_error} = ProductManager.run(params, context)
  end
end

defmodule Pyre.Actions.DesignerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.Designer
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_des_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates design spec from requirements", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Design Spec\n\nPage layout and components.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Product listing with search",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = Designer.run(params, context)
    assert result.design =~ "Design Spec"
    assert {:ok, content} = Artifact.read(run_dir, "02_design_spec")
    assert content =~ "Design Spec"
  end
end

defmodule Pyre.Actions.ProgrammerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.Programmer
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_prog_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates implementation summary", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Implementation\n\nCreated LiveView module.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements content",
      design: "Design content",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = Programmer.run(params, context)
    assert result.implementation =~ "Implementation"
    assert {:ok, _} = Artifact.read(run_dir, "03_implementation_summary")
  end

  test "writes versioned artifact on cycle 2+", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Implementation v2\n\nFixed issues.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      run_dir: run_dir,
      review_cycle: 2,
      previous_verdict: "REJECT\n\nNeeds fixes."
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, _result} = Programmer.run(params, context)
    assert {:ok, _} = Artifact.read(run_dir, "03_implementation_summary_v2")
  end
end

defmodule Pyre.Actions.TestWriterTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.TestWriter
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_tw_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates test summary", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Test Summary\n\nAll tests pass.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      implementation: "Implementation",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = TestWriter.run(params, context)
    assert result.tests =~ "Test Summary"
    assert {:ok, _} = Artifact.read(run_dir, "04_test_summary")
  end

  test "writes versioned artifact on cycle 2+", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Tests v2\n\nImproved coverage.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      implementation: "Implementation",
      run_dir: run_dir,
      review_cycle: 2,
      previous_verdict: "REJECT\n\nNeed more tests."
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, _result} = TestWriter.run(params, context)
    assert {:ok, _} = Artifact.read(run_dir, "04_test_summary_v2")
  end
end

defmodule Pyre.Actions.QAReviewerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.QAReviewer
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_qa_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "approves and writes verdict artifact", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "APPROVE\n\nGreat work!")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      implementation: "Implementation",
      tests: "Tests",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = QAReviewer.run(params, context)
    assert result.verdict == :approve
    assert result.verdict_text =~ "APPROVE"
    assert {:ok, _} = Artifact.read(run_dir, "05_review_verdict")
  end

  test "rejects when verdict is not APPROVE", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "REJECT\n\nNeeds more tests.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      implementation: "Implementation",
      tests: "Tests",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = QAReviewer.run(params, context)
    assert result.verdict == :reject
  end

  test "parse_verdict detects APPROVE case-insensitively" do
    assert QAReviewer.parse_verdict("APPROVE\nLooks good.") == :approve
    assert QAReviewer.parse_verdict("approve\nLooks good.") == :approve
    assert QAReviewer.parse_verdict("Approved with notes") == :approve
  end

  test "parse_verdict treats non-APPROVE as reject" do
    assert QAReviewer.parse_verdict("REJECT\nNeeds work.") == :reject
    assert QAReviewer.parse_verdict("NEEDS WORK") == :reject
    assert QAReviewer.parse_verdict("") == :reject
  end

  test "parse_verdict handles leading whitespace" do
    assert QAReviewer.parse_verdict("  APPROVE\nLooks good.") == :approve
    assert QAReviewer.parse_verdict("\n\nAPPROVE") == :approve
  end

  test "writes versioned verdict artifact on cycle 2+", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "APPROVE\n\nBetter now.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      implementation: "Implementation",
      tests: "Tests",
      run_dir: run_dir,
      review_cycle: 2
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, _result} = QAReviewer.run(params, context)
    assert {:ok, _} = Artifact.read(run_dir, "05_review_verdict_v2")
  end
end
