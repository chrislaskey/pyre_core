defmodule Pyre.RunServer do
  @moduledoc """
  GenServer managing a single Pyre pipeline run.

  Each run gets its own process, supervised by `Pyre.RunSupervisor` and
  registered by ID in `Pyre.RunRegistry`. The server buffers all log/output
  entries so reconnecting LiveViews can catch up.

  ## Usage

      {:ok, run_id} = Pyre.RunServer.start_run("Build a products page", llm: Pyre.LLM.Mock)
      {:ok, state} = Pyre.RunServer.get_state(run_id)
      {:ok, entries} = Pyre.RunServer.get_log(run_id)
      runs = Pyre.RunServer.list_runs()
  """

  use GenServer

  @type run_id :: String.t()

  # --- Public API ---

  @doc """
  Starts a new run under `Pyre.RunSupervisor`.

  Returns `{:ok, run_id}` where `run_id` is an 8-char hex string.
  """
  @spec start_run(String.t(), keyword()) :: {:ok, run_id()}
  def start_run(feature_description, opts \\ []) do
    id = generate_id()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Pyre.RunSupervisor,
        {__MODULE__, {id, feature_description, opts}}
      )

    {:ok, id}
  end

  @doc """
  Returns the full state of a run.
  """
  @spec get_state(run_id()) :: {:ok, map()} | {:error, :not_found}
  def get_state(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_state)}
      error -> error
    end
  end

  @doc """
  Returns the buffered log entries for a run.
  """
  @spec get_log(run_id()) :: {:ok, [map()]} | {:error, :not_found}
  def get_log(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_log)}
      error -> error
    end
  end

  @doc """
  Lists all active runs with summary metadata.
  """
  @spec list_runs() :: [map()]
  def list_runs do
    match_pattern = {:"$1", :_, :"$2"}
    guards = []
    body = [%{id: :"$1", meta: :"$2"}]

    Registry.select(Pyre.RunRegistry, [{match_pattern, guards, body}])
    |> Enum.map(fn %{id: id, meta: meta} -> Map.put(meta, :id, id) end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  # --- GenServer callbacks ---

  def start_link({id, _feature_description, _opts} = init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: via(id))
  end

  def child_spec({id, _feature_description, _opts} = init_arg) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary
    }
  end

  @impl true
  def init({id, feature_description, opts}) do
    now = DateTime.utc_now()

    state = %{
      id: id,
      status: :running,
      phase: :planning,
      feature_description: feature_description,
      log: [],
      started_at: now,
      completed_at: nil,
      opts: opts
    }

    update_registry_meta(state)

    # Start the flow task after init returns
    {:ok, state, {:continue, :start_flow}}
  end

  @impl true
  def handle_continue(:start_flow, state) do
    server = self()

    flow_opts =
      state.opts
      |> Keyword.put(:log_fn, fn msg -> GenServer.cast(server, {:log, msg}) end)
      |> Keyword.put(:output_fn, fn chunk -> GenServer.cast(server, {:output, chunk}) end)
      |> Keyword.put(:streaming, Keyword.get(state.opts, :streaming, true))

    task =
      Task.Supervisor.async_nolink(Jido.Action.TaskSupervisor, fn ->
        Pyre.Flows.FeatureBuild.run(state.feature_description, flow_opts)
      end)

    {:noreply, Map.put(state, :task_ref, task.ref)}
  end

  @impl true
  def handle_cast({:log, message}, state) do
    entry = make_entry(:log, message)
    state = append_entry(state, entry)

    # Detect phase changes from log messages
    state = maybe_update_phase(state, message)

    broadcast_event(state.id, entry)
    update_registry_meta(state)
    {:noreply, state}
  end

  def handle_cast({:output, chunk}, state) do
    entry = make_entry(:output, chunk)
    state = append_entry(state, entry)
    broadcast_event(state.id, entry)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = Map.drop(state, [:opts, :task_ref])
    {:reply, reply, state}
  end

  def handle_call(:get_log, _from, state) do
    {:reply, state.log, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    {status, entry} =
      case result do
        {:ok, _} ->
          {:complete, make_entry(:log, "Pipeline complete.")}

        {:error, reason} ->
          {:error, make_entry(:error, "Error: #{inspect(reason)}")}
      end

    state =
      state
      |> append_entry(entry)
      |> Map.merge(%{status: status, completed_at: DateTime.utc_now(), task_ref: nil})

    broadcast_event(state.id, entry)
    broadcast_status(state.id, status)
    update_registry_meta(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state)
      when reason != :normal do
    entry = make_entry(:error, "Task crashed: #{inspect(reason)}")

    state =
      state
      |> append_entry(entry)
      |> Map.merge(%{status: :error, completed_at: DateTime.utc_now(), task_ref: nil})

    broadcast_event(state.id, entry)
    broadcast_status(state.id, :error)
    update_registry_meta(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp via(id) do
    {:via, Registry, {Pyre.RunRegistry, id, %{}}}
  end

  defp lookup(id) do
    case Registry.lookup(Pyre.RunRegistry, id) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp make_entry(type, content) do
    %{
      id: "entry-#{System.unique_integer([:positive, :monotonic])}",
      type: type,
      content: content,
      timestamp: DateTime.utc_now()
    }
  end

  defp append_entry(state, entry) do
    Map.update!(state, :log, &(&1 ++ [entry]))
  end

  defp maybe_update_phase(state, message) do
    cond do
      message =~ ~r/Stage: product_manager/ -> %{state | phase: :planning}
      message =~ ~r/Stage: designer/ -> %{state | phase: :designing}
      message =~ ~r/Stage: programmer/ -> %{state | phase: :implementing}
      message =~ ~r/Stage: test_writer/ -> %{state | phase: :testing}
      message =~ ~r/Stage: code_reviewer/ -> %{state | phase: :reviewing}
      true -> state
    end
  end

  defp update_registry_meta(state) do
    meta = %{
      status: state.status,
      phase: state.phase,
      feature_description: state.feature_description,
      started_at: state.started_at,
      completed_at: state.completed_at
    }

    Registry.update_value(Pyre.RunRegistry, state.id, fn _old -> meta end)
  end

  defp pubsub do
    Application.get_env(:pyre, :pubsub)
  end

  defp broadcast_event(id, entry) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(ps, "pyre:runs:#{id}", {:pyre_run_event, id, entry})
    end
  end

  defp broadcast_status(id, status) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(ps, "pyre:runs:#{id}", {:pyre_run_status, id, status})
      Phoenix.PubSub.broadcast(ps, "pyre:runs", {:pyre_run_status, id, status})
    end
  end
end
