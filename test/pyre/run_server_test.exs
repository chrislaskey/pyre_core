defmodule Pyre.RunServerTest do
  use ExUnit.Case, async: false

  defmodule AgentMock do
    @behaviour Pyre.LLM

    @agent_name __MODULE__.Responses

    def setup(responses) do
      case GenServer.whereis(@agent_name) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      {:ok, _pid} = Agent.start_link(fn -> responses end, name: @agent_name)
      :ok
    end

    def teardown do
      case GenServer.whereis(@agent_name) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    defp next do
      Agent.get_and_update(@agent_name, fn
        [r | rest] -> {r, rest}
        [] -> {"Mock response (exhausted)", []}
      end)
    end

    @impl true
    def generate(_model, _messages, _opts \\ []), do: {:ok, next()}

    @impl true
    def stream(_model, _messages, _opts \\ []), do: {:ok, next()}

    @impl true
    def chat(_model, _messages, _tools, _opts \\ []) do
      text = next()

      response = %ReqLLM.Response{
        id: "mock_#{System.unique_integer([:positive])}",
        model: "mock",
        context: ReqLLM.Context.new(),
        finish_reason: :stop,
        message: %ReqLLM.Message{
          role: :assistant,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
        }
      }

      {:ok, response}
    end
  end

  setup do
    # Start a local PubSub for testing
    pubsub = Pyre.Test.PubSub

    case GenServer.whereis(pubsub) do
      nil -> start_supervised!({Phoenix.PubSub, name: pubsub})
      _pid -> :ok
    end

    Application.put_env(:pyre, :pubsub, pubsub)

    tmp_dir =
      Path.join(System.tmp_dir!(), "pyre_run_server_test_#{System.unique_integer([:positive])}")

    features_dir = Path.join(tmp_dir, "priv/pyre/features")
    File.mkdir_p!(features_dir)

    on_exit(fn ->
      AgentMock.teardown()
      Application.delete_env(:pyre, :pubsub)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, pubsub: pubsub}
  end

  test "start_run/2 returns {:ok, id} where id is 8-char hex", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    assert is_binary(id)
    assert String.length(id) == 8
    assert Regex.match?(~r/^[0-9a-f]{8}$/, id)

    # Wait for the run to finish
    wait_for_status(id, :complete)
  end

  test "get_state/1 returns state with correct fields", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert state.id == id
    assert state.status in [:running, :complete]
    assert state.feature_description == "Build a page"
    assert %DateTime{} = state.started_at

    wait_for_status(id, :complete)
  end

  test "get_log/1 returns buffered entries", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    wait_for_status(id, :complete)

    {:ok, log} = Pyre.RunServer.get_log(id)
    assert is_list(log)
    assert length(log) > 0
    assert Enum.all?(log, &(is_map(&1) and Map.has_key?(&1, :id)))
  end

  test "list_runs/0 includes started run with summary", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    runs = Pyre.RunServer.list_runs()
    run = Enum.find(runs, &(&1.id == id))

    assert run != nil
    assert run.feature_description == "Build a page"
    assert run.status in [:running, :complete]

    wait_for_status(id, :complete)
  end

  test "PubSub events are received by subscribers", %{tmp_dir: tmp_dir, pubsub: pubsub} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    Phoenix.PubSub.subscribe(pubsub, "pyre:runs:#{id}")

    wait_for_status(id, :complete)

    # We should have received at least some events
    messages = flush_messages()
    assert length(messages) > 0
  end

  test "completed run has :complete status and 'Pipeline complete.' in log", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    wait_for_status(id, :complete)

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert state.status == :complete
    assert %DateTime{} = state.completed_at

    {:ok, log} = Pyre.RunServer.get_log(id)
    contents = Enum.map(log, & &1.content)
    assert Enum.any?(contents, &(&1 == "Pipeline complete."))
  end

  test "skipped stages use best practices fallback", %{tmp_dir: tmp_dir} do
    # Only need 4 mock responses: product_manager, programmer, test_writer, shipper
    # designer and code_reviewer are skipped (skipped reviewer gives approve fallback → shipping)
    AgentMock.setup([
      "Req.",
      "Impl.",
      "Tests.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir,
        skipped_stages: [:designing, :reviewing]
      )

    wait_for_status(id, :complete)

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert state.status == :complete
    assert MapSet.member?(state.skipped_stages, :designing)
    assert MapSet.member?(state.skipped_stages, :reviewing)

    {:ok, log} = Pyre.RunServer.get_log(id)
    contents = Enum.map(log, & &1.content)
    assert Enum.any?(contents, &String.contains?(&1, "Skipping: designer"))
    assert Enum.any?(contents, &String.contains?(&1, "Skipping: code_reviewer"))
  end

  test "toggle_stage/2 adds and removes stages", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    # Initially no skipped stages
    {:ok, skipped} = Pyre.RunServer.get_skipped_stages(id)
    assert MapSet.size(skipped) == 0

    # Toggle designing off
    :ok = Pyre.RunServer.toggle_stage(id, :designing)
    {:ok, skipped} = Pyre.RunServer.get_skipped_stages(id)
    assert MapSet.member?(skipped, :designing)

    # Toggle designing back on
    :ok = Pyre.RunServer.toggle_stage(id, :designing)
    {:ok, skipped} = Pyre.RunServer.get_skipped_stages(id)
    refute MapSet.member?(skipped, :designing)

    wait_for_status(id, :complete)
  end

  test "get_state/1 returns {:error, :not_found} for unknown ID" do
    assert {:error, :not_found} = Pyre.RunServer.get_state("deadbeef")
  end

  test "get_log/1 returns {:error, :not_found} for unknown ID" do
    assert {:error, :not_found} = Pyre.RunServer.get_log("deadbeef")
  end

  test "get_state/1 includes interactive_stages and waiting_for_input fields", %{
    tmp_dir: tmp_dir
  } do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert %MapSet{} = state.interactive_stages
    assert MapSet.size(state.interactive_stages) == 0
    assert state.waiting_for_input == false

    wait_for_status(id, :complete)
  end

  test "toggle_interactive_stage/2 adds and removes stages", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert MapSet.size(state.interactive_stages) == 0

    # Toggle on
    :ok = Pyre.RunServer.toggle_interactive_stage(id, :designing)
    {:ok, state} = Pyre.RunServer.get_state(id)
    assert MapSet.member?(state.interactive_stages, :designing)

    # Toggle off
    :ok = Pyre.RunServer.toggle_interactive_stage(id, :designing)
    {:ok, state} = Pyre.RunServer.get_state(id)
    refute MapSet.member?(state.interactive_stages, :designing)

    wait_for_status(id, :complete)
  end

  test "send_reply/2 is a no-op when not waiting for input", %{tmp_dir: tmp_dir} do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    # Should not crash — guard ignores user_action when waiting_for_input == false
    assert :ok = Pyre.RunServer.send_reply(id, "some reply")
    assert :ok = Pyre.RunServer.continue_stage(id)

    wait_for_status(id, :complete)
  end

  test "interactive flow: send_reply unblocks waiting stage then continue advances", %{
    tmp_dir: tmp_dir,
    pubsub: pubsub
  } do
    # This mock returns responses in sequence. After a reply is sent the flow
    # calls chat/4 again with --resume, which consumes the next response.
    AgentMock.setup([
      # planning (non-interactive)
      "Requirements doc.",
      # designing (interactive) — initial call
      "Design spec.",
      # designing — resume call with user reply
      "Updated design spec with error states.",
      # designing — finalize call
      "Final design spec.",
      # remaining stages (non-interactive)
      "Architecture plan.",
      "Branch setup done.",
      "Implementation summary.",
      "PR reviewed."
    ])

    Phoenix.PubSub.subscribe(pubsub, "pyre:runs:#{:waiting_test}")

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :iterative_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    # Enable interactive for designing phase
    :ok = Pyre.RunServer.toggle_interactive_stage(id, :designing)

    Phoenix.PubSub.subscribe(pubsub, "pyre:runs:#{id}")

    # Wait for the flow to reach waiting_for_input
    assert wait_for_waiting(id), "Expected run to reach waiting_for_input state"

    {:ok, state} = Pyre.RunServer.get_state(id)
    assert state.waiting_for_input == true

    # Send a reply — flow should resume and come back to waiting
    :ok = Pyre.RunServer.send_reply(id, "Can you add error states?")
    assert wait_for_waiting(id), "Expected run to re-enter waiting after reply"

    # Continue — flow should finalize and advance
    :ok = Pyre.RunServer.continue_stage(id)

    wait_for_status(id, :complete)

    {:ok, final_state} = Pyre.RunServer.get_state(id)
    assert final_state.status == :complete
    assert final_state.waiting_for_input == false
  end

  test "toggle_interactive_stage/2 broadcasts pyre_interactive_stages", %{
    tmp_dir: tmp_dir,
    pubsub: pubsub
  } do
    AgentMock.setup([
      "Req.",
      "Design.",
      "Impl.",
      "Tests.",
      "APPROVE\n\nGood.",
      "## Branch Name\n\nfeature/page\n\n## Commit Message\n\nfeat: add page\n\n## PR Title\n\nAdd page\n\n## PR Body\n\nAdds page."
    ])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
        workflow: :feature_build,
        llm: AgentMock,
        streaming: false,
        project_dir: tmp_dir
      )

    Phoenix.PubSub.subscribe(pubsub, "pyre:runs:#{id}")

    :ok = Pyre.RunServer.toggle_interactive_stage(id, :designing)

    assert_receive {:pyre_interactive_stages, ^id, stages}, 1_000
    assert MapSet.member?(stages, :designing)

    wait_for_status(id, :complete)
  end

  # --- Helpers ---

  defp wait_for_status(id, expected_status, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case Pyre.RunServer.get_state(id) do
        {:ok, %{status: ^expected_status}} ->
          :done

        {:ok, _} ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("Timed out waiting for status #{expected_status}")
          end

          Process.sleep(50)
          :continue

        {:error, :not_found} ->
          flunk("Run #{id} not found")
      end
    end)
    |> Enum.find(&(&1 == :done))
  end

  defp wait_for_waiting(id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      Stream.repeatedly(fn ->
        case Pyre.RunServer.get_state(id) do
          {:ok, %{waiting_for_input: true}} ->
            :done

          {:ok, %{status: status}} when status in [:complete, :stopped, :error] ->
            :not_waiting

          {:ok, _} ->
            if System.monotonic_time(:millisecond) > deadline do
              :timeout
            else
              Process.sleep(50)
              :continue
            end

          _ ->
            Process.sleep(50)
            :continue
        end
      end)
      |> Enum.find(fn r -> r != :continue end)

    result == :done
  end

  defp flush_messages do
    flush_messages([])
  end

  defp flush_messages(acc) do
    receive do
      msg -> flush_messages(acc ++ [msg])
    after
      100 -> acc
    end
  end
end
