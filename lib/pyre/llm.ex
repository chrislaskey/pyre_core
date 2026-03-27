defmodule Pyre.LLM do
  @moduledoc """
  LLM behaviour for Pyre.

  Implementations:
  - `Pyre.LLM.ReqLLM` — default, uses ReqLLM/jido_ai
  - `Pyre.LLM.ClaudeCLI` — Claude CLI subprocess backend
  - `Pyre.LLM.CursorCLI` — Cursor CLI subprocess backend
  - `Pyre.LLM.CodexCLI` — OpenAI Codex CLI subprocess backend
  - `Pyre.LLM.Mock` — test mock

  The `:llm` key in action context selects the implementation module.
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t() | [map()]}
  @type model :: String.t()

  @doc """
  Generates text from the LLM without streaming.
  """
  @callback generate(model(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Generates text from the LLM with token-by-token streaming.

  Calls `output_fn` (default `&IO.write/1`) with each token as it arrives.
  Returns the complete response text.
  """
  @callback stream(model(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Calls the LLM with tool support, returning the full response.

  Used by the agentic loop for multi-turn tool-use conversations.
  ReqLLM-backed implementations return `ReqLLM.Response.t()`.
  CLI backends return plain `String.t()` (they manage their own tool loop).
  """
  @callback chat(model(), [message()] | ReqLLM.Context.t(), [ReqLLM.Tool.t()], keyword()) ::
              {:ok, ReqLLM.Response.t() | String.t()} | {:error, term()}

  @doc """
  Returns true if this backend manages its own tool-use loop internally.

  When true, `Pyre.Actions.Helpers.call_llm/4` calls `chat/4` directly
  instead of routing through `Pyre.Tools.AgenticLoop`.
  """
  @callback manages_tool_loop?() :: boolean()

  @optional_callbacks [manages_tool_loop?: 0]

  @doc """
  Returns the default LLM module based on application config.

  Reads `:pyre, :llm_backend` — defaults to `:req_llm`.
  Set `PYRE_LLM_BACKEND=claude_cli` to use the Claude CLI backend.
  Set `PYRE_LLM_BACKEND=cursor_cli` to use the Cursor CLI backend.
  Set `PYRE_LLM_BACKEND=codex_cli` to use the OpenAI Codex CLI backend.
  """
  def default do
    case Application.get_env(:pyre, :llm_backend, :req_llm) do
      :claude_cli -> Pyre.LLM.ClaudeCLI
      :cursor_cli -> Pyre.LLM.CursorCLI
      :codex_cli -> Pyre.LLM.CodexCLI
      :req_llm -> Pyre.LLM.ReqLLM
      module when is_atom(module) -> module
    end
  end
end
