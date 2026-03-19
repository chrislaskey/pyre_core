defmodule Pyre.Actions.ShipperTest do
  use ExUnit.Case, async: false

  alias Pyre.Actions.Shipper
  alias Pyre.Plugins.Artifact

  @llm_response """
  ## Branch Name

  feature-products-page

  ## Commit Message

  feat: add products listing page with search and pagination

  ## PR Title

  Add products listing page

  ## PR Body

  Implements a products listing page with:
  - Search functionality
  - Pagination support
  - Responsive layout
  """

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pyre_shipper_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{run_dir: run_dir}
  end

  defp base_params(run_dir) do
    %{
      feature_description: "Build a products page",
      requirements: "Product listing requirements",
      design: "Design spec content",
      implementation: "Implementation summary",
      tests: "Test summary",
      verdict_text: "APPROVE\nGreat work!",
      run_dir: run_dir
    }
  end

  describe "run/2 in dry_run mode" do
    test "generates shipping plan and writes artifact", %{run_dir: run_dir} do
      Process.put(:mock_llm_response, @llm_response)

      params = base_params(run_dir)
      context = %{llm: Pyre.LLM.Mock, streaming: false, dry_run: true}

      assert {:ok, result} = Shipper.run(params, context)
      assert result.shipping_summary =~ "Branch Name"
      assert result.shipping_summary =~ "PR Title"
      assert {:ok, content} = Artifact.read(run_dir, "06_shipping_summary")
      assert content =~ "Branch Name"
    end
  end

  describe "run/2 in non-git directory" do
    test "skips git operations and writes artifact", %{run_dir: run_dir} do
      Process.put(:mock_llm_response, @llm_response)

      params = base_params(run_dir)

      context = %{
        llm: Pyre.LLM.Mock,
        streaming: false,
        working_dir: run_dir,
        log_fn: &Function.identity/1
      }

      assert {:ok, result} = Shipper.run(params, context)
      assert result.shipping_summary =~ "Branch Name"
    end
  end

  describe "run/2 returns error on LLM failure" do
    test "propagates LLM error", %{run_dir: run_dir} do
      defmodule FailingShipperLLM do
        @behaviour Pyre.LLM
        def generate(_, _, _ \\ []), do: {:error, :api_error}
        def stream(_, _, _ \\ []), do: {:error, :api_error}
        def chat(_, _, _, _ \\ []), do: {:error, :api_error}
      end

      params = base_params(run_dir)
      context = %{llm: FailingShipperLLM, streaming: false, dry_run: true}

      assert {:error, :api_error} = Shipper.run(params, context)
    end
  end

  describe "run/2 with missing GitHub config" do
    test "returns friendly error when GitHub is not configured", %{run_dir: run_dir} do
      Process.put(:mock_llm_response, @llm_response)

      # Create a temporary git repo so we reach the config check
      git_dir =
        Path.join(System.tmp_dir!(), "pyre_git_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(git_dir)
      System.cmd("git", ["init"], cd: git_dir)
      on_exit(fn -> File.rm_rf!(git_dir) end)

      params = base_params(run_dir)

      context = %{
        llm: Pyre.LLM.Mock,
        streaming: false,
        working_dir: git_dir,
        github: %{},
        log_fn: &Function.identity/1
      }

      assert {:error, {:github_not_configured, message}} = Shipper.run(params, context)
      assert message =~ "GitHub is not configured"
    end
  end

  describe "run/2 with CLI backend (manages_tool_loop?)" do
    test "skips tools and routes to generate instead of chat", %{run_dir: run_dir} do
      defmodule CLIShipperBackend do
        @behaviour Pyre.LLM

        def manages_tool_loop?, do: true

        def generate(_, _, _ \\ []) do
          {:ok, """
          ## Branch Name

          feature-cli-test-branch

          ## Commit Message

          feat: test cli backend path

          ## PR Title

          Test CLI Backend Path

          ## PR Body

          Verifies that the CLI backend uses generate instead of chat.
          """}
        end

        def stream(_, _, _ \\ []), do: generate(nil, nil)

        def chat(_, _, _, _ \\ []) do
          raise "chat/4 should not be called for shipper with CLI backend"
        end
      end

      params = base_params(run_dir)
      context = %{llm: CLIShipperBackend, streaming: false, dry_run: true}

      assert {:ok, result} = Shipper.run(params, context)
      assert result.shipping_summary =~ "feature-cli-test-branch"
      assert result.shipping_summary =~ "Test CLI Backend Path"
    end
  end

  describe "parse_shipping_plan/1" do
    test "parses all sections from LLM output" do
      plan = Shipper.parse_shipping_plan(@llm_response)

      assert plan.branch_name == "feature-products-page"
      assert plan.commit_message =~ "feat: add products listing"
      assert plan.pr_title == "Add products listing page"
      assert plan.pr_body =~ "Search functionality"
    end

    test "provides defaults for missing sections" do
      plan = Shipper.parse_shipping_plan("Some random text without sections")

      assert plan.branch_name == "feature-pyre-changes"
      assert plan.commit_message == "feat: implement pyre-changes"
      assert plan.pr_title == "Implement pyre-changes"
      assert plan.pr_body == ""
    end

    test "derives defaults from run_dir feature slug" do
      run_dir = "/tmp/priv/pyre/features/hello-world/20260319_142935"
      plan = Shipper.parse_shipping_plan("No sections here", run_dir)

      assert plan.branch_name == "feature-hello-world"
      assert plan.commit_message == "feat: implement hello-world"
      assert plan.pr_title == "Implement hello-world"
    end

    test "derives defaults from feature_description when run_dir has no slug" do
      # Simulates the case where :feature opt was not passed to the flow
      run_dir = "/tmp/priv/pyre/features/20260319_142935/20260319_142935"
      plan = Shipper.parse_shipping_plan("No sections", run_dir, "Build a products page")

      assert plan.branch_name == "feature-build-a-products-page"
      assert plan.commit_message == "feat: implement build-a-products-page"
      assert plan.pr_title == "Implement build-a-products-page"
    end

    test "derives defaults from feature_description when run_dir is nil" do
      plan = Shipper.parse_shipping_plan("No sections", nil, "Add user authentication")

      assert plan.branch_name == "feature-add-user-authentication"
    end

    test "strips code fences from commit message" do
      text = """
      ## Branch Name

      feature-test

      ## Commit Message

      ```
      feat: some feature
      ```

      ## PR Title

      Some Feature

      ## PR Body

      Details here.
      """

      plan = Shipper.parse_shipping_plan(text)
      refute plan.commit_message =~ "```"
      assert plan.commit_message =~ "feat: some feature"
    end
  end
end
