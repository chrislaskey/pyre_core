defmodule Pyre.Actions.SoftwareArchitectTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.SoftwareArchitect
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_sa_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates architecture plan and writes artifact", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Architecture Plan\n\n## Phase 1\n\nSetup schema.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Product listing requirements",
      design: "Design spec content",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = SoftwareArchitect.run(params, context)
    assert result.architecture_plan =~ "Architecture Plan"
    assert {:ok, content} = Artifact.read(run_dir, "03_architecture_plan")
    assert content =~ "Architecture Plan"
  end
end

defmodule Pyre.Actions.BranchSetupTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.BranchSetup
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_bs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "dry run writes artifact and returns branch name", %{run_dir: run_dir} do
    Process.put(
      :mock_llm_response,
      "## Branch Name\n\nfeature/products-page\n\n## PR Title\n\nAdd products page\n\n## PR Body\n\nImplements products page."
    )

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      architecture_plan: "Architecture plan",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false, dry_run: true}

    assert {:ok, result} = BranchSetup.run(params, context)
    assert result.branch_name == "feature/products-page"
    assert result.branch_setup =~ "Branch Name"
    assert {:ok, _content} = Artifact.read(run_dir, "04_branch_setup")
  end

  test "non-git-repo skips git operations", %{run_dir: run_dir} do
    Process.put(
      :mock_llm_response,
      "## Branch Name\n\nfeature/change\n\n## PR Title\n\nChange\n\n## PR Body\n\nChange."
    )

    # Use a temp dir that is definitely not a git repo
    non_git_dir =
      Path.join(System.tmp_dir!(), "pyre_bs_nogit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(non_git_dir)

    params = %{
      feature_description: "Build something",
      requirements: "Requirements",
      design: "Design",
      architecture_plan: "Architecture plan",
      run_dir: run_dir
    }

    context = %{
      llm: Pyre.LLM.Mock,
      streaming: false,
      working_dir: non_git_dir,
      log_fn: fn _ -> :ok end
    }

    assert {:ok, result} = BranchSetup.run(params, context)
    assert result.branch_name == "feature/change"

    File.rm_rf!(non_git_dir)
  end
end

defmodule Pyre.Actions.SoftwareEngineerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.SoftwareEngineer
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_se_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "generates implementation summary and writes artifact", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "# Implementation Summary\n\nAll phases implemented.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      architecture_plan: "Architecture plan",
      branch_setup: "Branch setup summary",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false}

    assert {:ok, result} = SoftwareEngineer.run(params, context)
    assert result.implementation_summary =~ "Implementation Summary"
    assert {:ok, content} = Artifact.read(run_dir, "06_implementation_summary")
    assert content =~ "Implementation Summary"
  end
end

defmodule Pyre.Actions.PRReviewerTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.PRReviewer
  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_prr_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  test "approves and writes review artifact", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "APPROVE\n\nGreat work!")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      architecture_plan: "Architecture plan",
      implementation_summary: "Implementation summary",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false, log_fn: fn _ -> :ok end}

    assert {:ok, result} = PRReviewer.run(params, context)
    assert result.verdict == :approve
    assert result.review =~ "APPROVE"
    assert {:ok, _content} = Artifact.read(run_dir, "07_pr_review")
  end

  test "rejects when verdict is not APPROVE", %{run_dir: run_dir} do
    Process.put(:mock_llm_response, "REJECT\n\nNeeds more test coverage.")

    params = %{
      feature_description: "Build a products page",
      requirements: "Requirements",
      design: "Design",
      architecture_plan: "Architecture plan",
      implementation_summary: "Implementation summary",
      run_dir: run_dir
    }

    context = %{llm: Pyre.LLM.Mock, streaming: false, log_fn: fn _ -> :ok end}

    assert {:ok, result} = PRReviewer.run(params, context)
    assert result.verdict == :reject
  end
end
