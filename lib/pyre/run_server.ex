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

  # 7 days — long enough for any real session, short enough to bound abandoned runs.
  @interactive_wait_timeout 604_800_000

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
  Returns the set of skipped stages for a run.
  """
  @spec get_skipped_stages(run_id()) :: {:ok, MapSet.t()} | {:error, :not_found}
  def get_skipped_stages(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_skipped_stages)}
      error -> error
    end
  end

  @doc """
  Toggles a stage on or off. If the stage is currently skipped, it becomes
  enabled; if enabled, it becomes skipped. Broadcasts the updated set.
  """
  @spec toggle_stage(run_id(), atom()) :: :ok | {:error, :not_found}
  def toggle_stage(id, stage) do
    case lookup(id) do
      {:ok, pid} -> GenServer.call(pid, {:toggle_stage, stage})
      error -> error
    end
  end

  @doc """
  Toggles interactive mode on or off for a specific stage. When on, the flow
  pauses after that stage completes and waits for user input. Broadcasts the
  updated set. Only affects stages that haven't started yet.
  """
  @spec toggle_interactive_stage(run_id(), atom()) :: :ok | {:error, :not_found}
  def toggle_interactive_stage(id, stage) do
    case lookup(id) do
      {:ok, pid} -> GenServer.call(pid, {:toggle_interactive_stage, stage})
      error -> error
    end
  end

  @doc """
  Sends a reply to the currently waiting stage. The flow resumes the Claude CLI
  session with the given text and streams the response back to the web UI.
  No-ops if the run is not currently waiting for input.
  """
  @spec send_reply(run_id(), String.t()) :: :ok | {:error, :not_found}
  def send_reply(id, text) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:user_action, {:reply, text}})
      error -> error
    end
  end

  @doc """
  Advances the run past the current waiting stage. If replies were sent during
  the wait, a finalize call is made before advancing. No-ops if the run is not
  currently waiting for input.
  """
  @spec continue_stage(run_id()) :: :ok | {:error, :not_found}
  def continue_stage(id) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:user_action, :continue})
      error -> error
    end
  end

  @doc """
  Stops a running pipeline. Kills the flow task and marks the run as stopped.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec stop_run(run_id()) :: :ok | {:error, :not_found | :not_running}
  def stop_run(id) do
    case lookup(id) do
      {:ok, pid} -> GenServer.call(pid, :stop_run)
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

    skipped =
      opts
      |> Keyword.get(:skipped_stages, [])
      |> MapSet.new()

    interactive =
      opts
      |> Keyword.get(:interactive_stages, [])
      |> MapSet.new()

    workflow = Keyword.get(opts, :workflow, :iterative_build)
    llm = Keyword.get(opts, :llm, Pyre.LLM.default())
    backend = if llm == Pyre.LLM.ClaudeCLI, do: :claude_cli, else: :other

    state = %{
      id: id,
      status: :running,
      phase: :planning,
      workflow: workflow,
      backend: backend,
      feature: Keyword.get(opts, :feature),
      feature_description: feature_description,
      log: [],
      started_at: now,
      completed_at: nil,
      skipped_stages: skipped,
      interactive_stages: interactive,
      waiting_for_input: false,
      pending_from: nil,
      session_ids: %{},
      opts: opts
    }

    update_registry_meta(state)

    # Start the flow task after init returns
    {:ok, state, {:continue, :start_flow}}
  end

  @impl true
  def handle_continue(:start_flow, state) do
    server = self()
    stages = workflow_stages(state.workflow)
    session_ids = Pyre.Session.generate_for_stages(stages)

    flow_opts =
      state.opts
      |> Keyword.put(:log_fn, fn msg -> GenServer.cast(server, {:log, msg}) end)
      |> Keyword.put(:output_fn, fn chunk -> GenServer.cast(server, {:output, chunk}) end)
      |> Keyword.put(:streaming, Keyword.get(state.opts, :streaming, true))
      |> Keyword.put(:skip_check_fn, fn phase ->
        GenServer.call(server, {:stage_skipped?, phase})
      end)
      |> Keyword.put(:interactive_stage_fn, fn phase ->
        GenServer.call(server, {:interactive_stage?, phase})
      end)
      |> Keyword.put(:await_user_action_fn, fn phase ->
        GenServer.call(server, {:await_user_action, phase}, @interactive_wait_timeout)
      end)
      |> Keyword.put(:session_ids, session_ids)

    flow_module = flow_module(state.workflow)

    task =
      Task.Supervisor.async_nolink(Jido.Action.TaskSupervisor, fn ->
        flow_module.run(state.feature_description, flow_opts)
      end)

    state =
      state
      |> Map.put(:session_ids, session_ids)
      |> Map.put(:task_ref, task.ref)
      |> Map.put(:task_pid, task.pid)

    {:noreply, state}
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

  # Guard: ignore user actions when not waiting (e.g. duplicate tab submits)
  def handle_cast({:user_action, _action}, %{waiting_for_input: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:user_action, :continue}, state) do
    GenServer.reply(state.pending_from, :continue)
    {:noreply, %{state | waiting_for_input: false, pending_from: nil}}
  end

  def handle_cast({:user_action, {:reply, text}}, state) do
    entry = make_entry(:user_reply, "> #{text}")
    state = append_entry(state, entry)
    broadcast_event(state.id, entry)
    GenServer.reply(state.pending_from, {:reply, text})
    state = %{state | waiting_for_input: false, pending_from: nil}
    broadcast_stage_resumed(state.id, state.phase)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply =
      state
      |> Map.drop([:opts, :task_ref, :task_pid, :pending_from])
      |> strip_attachment_content()

    {:reply, reply, state}
  end

  def handle_call(:get_log, _from, state) do
    {:reply, state.log, state}
  end

  def handle_call(:get_skipped_stages, _from, state) do
    {:reply, state.skipped_stages, state}
  end

  def handle_call({:toggle_stage, stage}, _from, state) do
    skipped =
      if MapSet.member?(state.skipped_stages, stage) do
        MapSet.delete(state.skipped_stages, stage)
      else
        MapSet.put(state.skipped_stages, stage)
      end

    state = %{state | skipped_stages: skipped}
    broadcast_skipped_stages(state.id, skipped)
    {:reply, :ok, state}
  end

  def handle_call({:stage_skipped?, phase}, _from, state) do
    {:reply, MapSet.member?(state.skipped_stages, phase), state}
  end

  def handle_call({:toggle_interactive_stage, stage}, _from, state) do
    interactive =
      if MapSet.member?(state.interactive_stages, stage) do
        MapSet.delete(state.interactive_stages, stage)
      else
        MapSet.put(state.interactive_stages, stage)
      end

    state = %{state | interactive_stages: interactive}
    broadcast_interactive_stages(state.id, interactive)
    {:reply, :ok, state}
  end

  def handle_call({:interactive_stage?, phase}, _from, state) do
    {:reply, MapSet.member?(state.interactive_stages, phase), state}
  end

  def handle_call({:await_user_action, phase}, from, state) do
    state = %{state | waiting_for_input: true, pending_from: from}
    broadcast_waiting_for_input(state.id, phase)
    update_registry_meta(state)
    # Deliberately do not reply yet — reply arrives via send_reply/1 or continue_stage/1
    {:noreply, state}
  end

  def handle_call(:stop_run, _from, %{status: :running, task_pid: pid, task_ref: ref} = state)
      when not is_nil(pid) do
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(Jido.Action.TaskSupervisor, pid)

    entry = make_entry(:log, "Pipeline stopped by user.")

    state =
      state
      |> append_entry(entry)
      |> Map.merge(%{
        status: :stopped,
        completed_at: DateTime.utc_now(),
        task_ref: nil,
        task_pid: nil,
        waiting_for_input: false,
        pending_from: nil
      })

    broadcast_event(state.id, entry)
    broadcast_status(state.id, :stopped)
    update_registry_meta(state)
    {:reply, :ok, state}
  end

  def handle_call(:stop_run, _from, state) do
    {:reply, {:error, :not_running}, state}
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
      |> Map.merge(%{
        status: status,
        completed_at: DateTime.utc_now(),
        task_ref: nil,
        task_pid: nil
      })

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
      |> Map.merge(%{
        status: :error,
        completed_at: DateTime.utc_now(),
        task_ref: nil,
        task_pid: nil,
        waiting_for_input: false,
        pending_from: nil
      })

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
    new_phase =
      cond do
        message =~ ~r/Stage: product_manager/ -> :planning
        message =~ ~r/Stage: designer/ -> :designing
        message =~ ~r/Stage: programmer/ -> :implementing
        message =~ ~r/Stage: test_writer/ -> :testing
        message =~ ~r/Stage: code_reviewer/ -> :reviewing
        message =~ ~r/Stage: shipper/ -> :shipping
        message =~ ~r/Stage: software_architect/ -> :architecting
        message =~ ~r/Stage: branch_setup/ -> :branch_setup
        message =~ ~r/Stage: software_engineer/ -> :engineering
        message =~ ~r/Stage: pr_reviewer/ -> :reviewing
        true -> nil
      end

    if new_phase && new_phase != state.phase do
      broadcast_phase(state.id, new_phase)
      %{state | phase: new_phase}
    else
      state
    end
  end

  defp flow_module(:iterative_build), do: Pyre.Flows.IterativeBuild
  defp flow_module(_), do: Pyre.Flows.FeatureBuild

  defp workflow_stages(:iterative_build) do
    [:planning, :designing, :architecting, :branch_setup, :engineering, :reviewing]
  end

  defp workflow_stages(_) do
    [:planning, :designing, :implementing, :testing, :reviewing, :shipping]
  end

  defp update_registry_meta(state) do
    meta = %{
      status: state.status,
      phase: state.phase,
      workflow: state.workflow,
      backend: state.backend,
      feature: state.feature,
      feature_description: state.feature_description,
      started_at: state.started_at,
      completed_at: state.completed_at,
      waiting_for_input: state.waiting_for_input
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

  defp broadcast_phase(id, phase) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(ps, "pyre:runs:#{id}", {:pyre_run_phase, id, phase})
    end
  end

  defp broadcast_skipped_stages(id, skipped_stages) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(
        ps,
        "pyre:runs:#{id}",
        {:pyre_run_skipped_stages, id, skipped_stages}
      )
    end
  end

  defp broadcast_interactive_stages(id, interactive_stages) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(
        ps,
        "pyre:runs:#{id}",
        {:pyre_interactive_stages, id, interactive_stages}
      )
    end
  end

  defp broadcast_waiting_for_input(id, phase) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(ps, "pyre:runs:#{id}", {:pyre_waiting_for_input, id, phase})
    end
  end

  defp broadcast_stage_resumed(id, phase) do
    if ps = pubsub() do
      Phoenix.PubSub.broadcast(ps, "pyre:runs:#{id}", {:pyre_stage_resumed, id, phase})
    end
  end

  defp strip_attachment_content(reply) do
    case Map.get(reply, :attachments) do
      nil ->
        reply

      attachments when is_list(attachments) ->
        stripped =
          Enum.map(attachments, fn att ->
            Map.take(att, [:filename, :media_type])
          end)

        Map.put(reply, :attachments, stripped)

      _ ->
        reply
    end
  end
end
