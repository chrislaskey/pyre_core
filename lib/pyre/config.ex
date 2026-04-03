defmodule Pyre.Config do
  @moduledoc """
  Behaviour and default configuration for Pyre lifecycle hooks.

  Applications can provide a custom config module by:

  1. Creating a module that `use Pyre.Config`
  2. Overriding any callbacks they need
  3. Configuring it in `config.exs`:

         config :pyre, config: MyApp.PyreConfig

  If no config module is set, `Pyre.Config` itself provides the default
  implementations for all callbacks.

  ## Example

      defmodule MyApp.PyreConfig do
        use Pyre.Config

        @impl true
        def after_flow_start(%Pyre.Events.FlowStarted{flow_module: mod}) do
          IO.puts("Flow started: \#{inspect(mod)}")
          :ok
        end

        @impl true
        def after_action_complete(%Pyre.Events.ActionCompleted{} = event) do
          MyApp.Telemetry.emit(:action_complete, %{
            stage: event.stage_name,
            elapsed_ms: event.elapsed_ms
          })
          :ok
        end
      end

  Any callback not overridden in the custom module will fall back to the
  default implementation provided by `Pyre.Config`.

  ## Dispatching

  Use `Pyre.Config.notify/2` to dispatch events. Exceptions raised inside
  user-provided callbacks are rescued and logged — they never crash the
  calling flow.
  """

  require Logger

  # -- Callbacks --

  @callback after_flow_start(event :: Pyre.Events.FlowStarted.t()) :: :ok | {:error, term()}
  @callback after_flow_complete(event :: Pyre.Events.FlowCompleted.t()) :: :ok | {:error, term()}
  @callback after_flow_error(event :: Pyre.Events.FlowError.t()) :: :ok | {:error, term()}
  @callback after_action_start(event :: Pyre.Events.ActionStarted.t()) :: :ok | {:error, term()}
  @callback after_action_complete(event :: Pyre.Events.ActionCompleted.t()) ::
              :ok | {:error, term()}
  @callback after_action_error(event :: Pyre.Events.ActionError.t()) :: :ok | {:error, term()}
  @callback after_llm_call_complete(event :: Pyre.Events.LLMCallCompleted.t()) ::
              :ok | {:error, term()}
  @callback after_llm_call_error(event :: Pyre.Events.LLMCallError.t()) :: :ok | {:error, term()}

  # -- Public API --

  @doc """
  Returns the configured Pyre config module.

  Reads `config :pyre, config: MyApp.PyreConfig` from the application environment.
  Falls back to `Pyre.Config` (default implementations) if none is configured.
  """
  def get_module do
    Application.get_env(:pyre, :config) || __MODULE__
  end

  @doc """
  Dispatches a lifecycle event to the configured config module.

  Rescues any exception raised inside the user's callback implementation
  and logs a warning — callbacks never crash the calling flow.
  """
  @spec notify(atom(), struct()) :: :ok
  def notify(hook, event) do
    mod = get_module()

    try do
      apply(mod, hook, [event])
    rescue
      e ->
        Logger.warning("Pyre.Config hook #{hook} raised: #{Exception.message(e)}")
    end

    :ok
  end

  # -- __using__ macro --

  defmacro __using__(_opts) do
    quote do
      @behaviour Pyre.Config

      @impl Pyre.Config
      def after_flow_start(_event), do: :ok
      @impl Pyre.Config
      def after_flow_complete(_event), do: :ok
      @impl Pyre.Config
      def after_flow_error(_event), do: :ok
      @impl Pyre.Config
      def after_action_start(_event), do: :ok
      @impl Pyre.Config
      def after_action_complete(_event), do: :ok
      @impl Pyre.Config
      def after_action_error(_event), do: :ok
      @impl Pyre.Config
      def after_llm_call_complete(_event), do: :ok
      @impl Pyre.Config
      def after_llm_call_error(_event), do: :ok

      defoverridable after_flow_start: 1,
                     after_flow_complete: 1,
                     after_flow_error: 1,
                     after_action_start: 1,
                     after_action_complete: 1,
                     after_action_error: 1,
                     after_llm_call_complete: 1,
                     after_llm_call_error: 1
    end
  end

  # -- Default implementations (used when no custom config module is configured) --

  def after_flow_start(_event), do: :ok
  def after_flow_complete(_event), do: :ok
  def after_flow_error(_event), do: :ok
  def after_action_start(_event), do: :ok
  def after_action_complete(_event), do: :ok
  def after_action_error(_event), do: :ok
  def after_llm_call_complete(_event), do: :ok
  def after_llm_call_error(_event), do: :ok
end
