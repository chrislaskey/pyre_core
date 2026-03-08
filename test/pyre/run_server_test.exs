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

    runs_dir = Path.join(tmp_dir, "priv/pyre/runs")
    File.mkdir_p!(runs_dir)

    on_exit(fn ->
      AgentMock.teardown()
      Application.delete_env(:pyre, :pubsub)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, pubsub: pubsub}
  end

  test "start_run/2 returns {:ok, id} where id is 8-char hex" do
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} = Pyre.RunServer.start_run("Build a page", llm: AgentMock, streaming: false)

    assert is_binary(id)
    assert String.length(id) == 8
    assert Regex.match?(~r/^[0-9a-f]{8}$/, id)

    # Wait for the run to finish
    wait_for_status(id, :complete)
  end

  test "get_state/1 returns state with correct fields", %{tmp_dir: tmp_dir} do
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    # Only need 3 mock responses: product_manager, programmer, test_writer
    # designer and code_reviewer are skipped
    AgentMock.setup(["Req.", "Impl.", "Tests."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
    AgentMock.setup(["Req.", "Design.", "Impl.", "Tests.", "APPROVE\n\nGood."])

    {:ok, id} =
      Pyre.RunServer.start_run("Build a page",
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
