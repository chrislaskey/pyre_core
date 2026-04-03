defmodule Pyre.LLM.CursorCLI do
  @moduledoc """
  LLM backend that delegates to the `cursor-agent` CLI subprocess.

  Uses `cursor-agent -p` (print mode) for non-interactive LLM calls.
  When called with tools via `chat/4`, the CLI runs its own internal
  agentic loop with built-in tools (Bash, file read/write, grep, etc.),
  bypassing Pyre's `AgenticLoop` entirely.

  ## Prerequisites

  The `cursor-agent` CLI must be installed and on PATH:

      curl https://cursor.com/install -fsSL | bash
      # Adds ~/.local/bin/cursor-agent; add to PATH if needed.

  A Cursor subscription is required. Authenticate via one of:

      cursor-agent login              # browser flow (recommended)
      export CURSOR_API_KEY=<key>     # API key for headless/CI

  ## Configuration

      # Select as default backend via env var:
      PYRE_LLM_BACKEND=cursor_cli

      # Or in config:
      config :pyre, :llm_backend, :cursor_cli

  ## Session Persistence (Option E — Hybrid Warm-Up)

  cursor-agent cannot accept a pre-specified session ID on the first call
  (unlike Claude CLI's `--session-id`). To support interactive stage replies,
  CursorCLI uses a warm-up strategy:

  1. On the first `chat/4` call with `session_id:`, a warm-up prompt
     containing the persona/system instructions is sent to create a
     cursor session. The cursor-generated session ID is extracted from
     the JSON output and stored in `Pyre.Session.Registry`.
  2. The real user prompt is then sent via `--resume <cursor_id>`.
  3. Subsequent `resume:` calls look up the cursor ID from the registry.

  This means the persona is loaded once in the warm-up and carries over
  to all subsequent calls in the session.

  ## Differences from ClaudeCLI

  - Session IDs are backend-generated, not caller-specified. The registry
    maps Pyre's pre-allocated UUIDs to cursor's real session IDs.
  - System prompt is embedded in the user message (same as ClaudeCLI's
    in-prompt embedding approach) rather than via a dedicated flag.
  - Permission bypass uses `--yolo` instead of `--permission-mode bypassPermissions`.
  - Multi-model access: cursor-agent can route to Claude, GPT, Gemini, etc.

  ## Cost

  When authenticated via `cursor-agent login` (Cursor subscription),
  CLI usage is included in the subscription at no per-token cost.
  """

  @behaviour Pyre.LLM

  require Logger

  @default_timeout 600_000

  @non_interactive_note "Note: This is a non-interactive session running inside an automated " <>
                          "pipeline. If you have questions or need clarification before " <>
                          "proceeding, include them clearly at the end of your response — " <>
                          "the user can reply by resuming this session."

  @impl true
  def manages_tool_loop?, do: true

  # --- generate/3 ---

  @impl true
  def generate(model, messages, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cli_model = map_model(model)
    {_system_prompt, user_prompt} = extract_prompts(messages)

    args =
      build_base_args(cli_model) ++
        ["--output-format", "json", "-p", user_prompt]

    case run_cli(args, timeout) do
      {:ok, output} -> parse_json_result(output)
      {:error, _} = error -> error
    end
  end

  # --- stream/3 ---

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cli_model = map_model(model)
    {_system_prompt, user_prompt} = extract_prompts(messages)

    args =
      build_base_args(cli_model) ++
        [
          "--output-format",
          "stream-json",
          "-p",
          user_prompt
        ]

    run_cli_streaming(args, output_fn, timeout)
  end

  # --- chat/4 ---

  @impl true
  def chat(model, messages, _tools, opts \\ []) do
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir)
    cli_model = map_model(model)
    {system_prompt, user_prompt} = extract_prompts(messages)

    Logger.info(
      "[CursorCLI] chat/4 model=#{cli_model} streaming=#{streaming?} prompt_len=#{byte_size(user_prompt)}"
    )

    run_opts = if working_dir, do: [cd: working_dir], else: []

    cond do
      # First call for a stage — warm up the session, then resume with real prompt
      pyre_session_id = opts[:session_id] ->
        case ensure_session(pyre_session_id, cli_model, system_prompt, run_opts) do
          {:ok, cursor_id} ->
            # Real prompt goes via --resume; persona is already in the session
            prompt = extract_user_parts(messages) <> "\n\n" <> @non_interactive_note

            run_with_session(
              cursor_id,
              cli_model,
              prompt,
              streaming?,
              output_fn,
              timeout,
              run_opts
            )

          {:error, _} ->
            Logger.warning("[CursorCLI] session warm-up failed, falling back to stateless call")

            run_stateless(
              cli_model,
              user_prompt <> "\n\n" <> @non_interactive_note,
              streaming?,
              output_fn,
              timeout,
              run_opts
            )
        end

      # Interactive reply — look up cursor session ID from registry
      pyre_resume_id = opts[:resume] ->
        case Pyre.Session.Registry.get(pyre_resume_id) do
          nil ->
            Logger.warning(
              "[CursorCLI] no session mapping for #{pyre_resume_id}, running stateless"
            )

            run_stateless(cli_model, user_prompt, streaming?, output_fn, timeout, run_opts)

          cursor_id ->
            prompt = extract_user_parts(messages)

            run_with_session(
              cursor_id,
              cli_model,
              prompt,
              streaming?,
              output_fn,
              timeout,
              run_opts
            )
        end

      # No session — stateless call
      true ->
        run_stateless(
          cli_model,
          user_prompt <> "\n\n" <> @non_interactive_note,
          streaming?,
          output_fn,
          timeout,
          run_opts
        )
    end
  end

  # --- Session Warm-Up (Option E) ---

  defp ensure_session(pyre_session_id, cli_model, system_prompt, run_opts) do
    case Pyre.Session.Registry.get(pyre_session_id) do
      nil ->
        warmup_prompt = build_warmup_prompt(system_prompt)

        Logger.info("[CursorCLI] warming up session for #{pyre_session_id}")

        args =
          build_base_args(cli_model) ++
            ["--yolo", "--output-format", "json", "-p", warmup_prompt]

        case run_cli(args, @default_timeout, run_opts) do
          {:ok, output} ->
            case extract_session_id(output) do
              {:ok, cursor_id} ->
                Pyre.Session.Registry.put(pyre_session_id, cursor_id)
                Logger.info("[CursorCLI] session mapped: #{pyre_session_id} -> #{cursor_id}")
                {:ok, cursor_id}

              :error ->
                {:error, :no_session_id_in_output}
            end

          {:error, _} = error ->
            error
        end

      cursor_id ->
        {:ok, cursor_id}
    end
  end

  defp build_warmup_prompt(system_prompt) when system_prompt == "" or is_nil(system_prompt) do
    "You are being initialized for a new task session. Reply with: READY"
  end

  defp build_warmup_prompt(system_prompt) do
    """
    #{system_prompt}

    You are being initialized for a new task session. Acknowledge that you \
    understand your role and are ready for the task prompt. Reply briefly with: READY\
    """
  end

  @doc false
  def extract_session_id(output) do
    trimmed = String.trim(output)

    # Try JSON array format first (--output-format json)
    with {:ok, items} when is_list(items) <- Jason.decode(trimmed) do
      session_id =
        Enum.find_value(items, fn
          %{"session_id" => id} when is_binary(id) and id != "" -> id
          _ -> nil
        end)

      if session_id, do: {:ok, session_id}, else: :error
    else
      _ ->
        # Try NDJSON (one JSON object per line)
        session_id =
          trimmed
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case Jason.decode(line) do
              {:ok, %{"session_id" => id}} when is_binary(id) and id != "" -> id
              _ -> nil
            end
          end)

        if session_id, do: {:ok, session_id}, else: :error
    end
  end

  defp run_with_session(cursor_id, cli_model, prompt, streaming?, output_fn, timeout, run_opts) do
    args = build_base_args(cli_model) ++ ["--yolo", "--resume", cursor_id]

    if streaming? do
      streaming_args = args ++ ["--output-format", "stream-json", "-p", prompt]
      run_cli_streaming(streaming_args, output_fn, timeout, run_opts)
    else
      batch_args = args ++ ["--output-format", "json", "-p", prompt]

      case run_cli(batch_args, timeout, run_opts) do
        {:ok, output} -> parse_json_result(output)
        {:error, _} = error -> error
      end
    end
  end

  defp run_stateless(cli_model, prompt, streaming?, output_fn, timeout, run_opts) do
    args = build_base_args(cli_model) ++ ["--yolo"]

    if streaming? do
      streaming_args = args ++ ["--output-format", "stream-json", "-p", prompt]
      run_cli_streaming(streaming_args, output_fn, timeout, run_opts)
    else
      batch_args = args ++ ["--output-format", "json", "-p", prompt]

      case run_cli(batch_args, timeout, run_opts) do
        {:ok, output} -> parse_json_result(output)
        {:error, _} = error -> error
      end
    end
  end

  @doc false
  def extract_user_parts(messages) when is_list(messages) do
    messages
    |> Enum.filter(fn %{role: role} -> role == :user end)
    |> Enum.map(fn %{content: content} -> to_text(content) end)
    |> Enum.join("\n\n")
  end

  def extract_user_parts(_), do: "Please continue."

  # --- Model Mapping ---

  @doc false
  def map_model("anthropic:claude-haiku" <> _), do: "claude-haiku-4-5"
  def map_model("anthropic:claude-sonnet" <> _), do: "claude-sonnet-4-5"
  def map_model("anthropic:claude-opus" <> _), do: "claude-opus-4"
  def map_model("haiku"), do: "claude-haiku-4-5"
  def map_model("sonnet"), do: "claude-sonnet-4-5"
  def map_model("opus"), do: "claude-opus-4"
  def map_model(other), do: other

  # --- Prompt Extraction ---

  @doc false
  def extract_prompts(messages) when is_list(messages) do
    system_parts =
      messages
      |> Enum.filter(fn %{role: role} -> role == :system end)
      |> Enum.map(fn %{content: content} -> to_text(content) end)
      |> Enum.join("\n\n")

    user_parts =
      messages
      |> Enum.filter(fn %{role: role} -> role == :user end)
      |> Enum.map(fn %{content: content} -> to_text(content) end)
      |> Enum.join("\n\n")

    # Embed persona/system instructions directly in the user prompt.
    # cursor-agent does not have a --append-system-prompt flag; this approach
    # works reliably since the underlying model follows in-prompt instructions.
    user_prompt =
      if system_parts != "" do
        """
        <persona>
        #{system_parts}
        </persona>

        You MUST follow the persona instructions above for the duration of this task. \
        Stay in character, use the output format specified, and do not deviate from the role described.

        #{user_parts}\
        """
      else
        user_parts
      end

    {system_parts, user_prompt}
  end

  def extract_prompts(_other), do: {"", "Please continue."}

  defp to_text(content) when is_binary(content), do: content

  defp to_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn p -> is_map(p) and Map.get(p, :type) == :text end)
    |> Enum.map_join("\n", fn p -> p.text end)
  end

  defp to_text(_), do: ""

  # --- CLI Execution (batch) ---

  defp run_cli(args, timeout, run_opts \\ []) do
    executable = cli_executable()

    task =
      Task.async(fn ->
        try do
          env = build_env()
          opts = [stderr_to_stdout: true, env: env] ++ run_opts

          # Wrap via shell to redirect stdin from /dev/null.
          # cursor-agent can block waiting for stdin EOF in headless mode.
          {:ok,
           System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" </dev/null), executable | args], opts)}
        rescue
          _ -> {:error, :cli_not_found}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, {output, 0}}} ->
        {:ok, output}

      {:ok, {:ok, {_output, 127}}} ->
        {:error, :cli_not_found}

      {:ok, {:ok, {output, exit_code}}} ->
        {:error, {:cli_error, exit_code, output}}

      {:ok, {:error, _} = error} ->
        error

      nil ->
        {:error, :timeout}
    end
  end

  # --- CLI Execution (streaming) ---

  defp run_cli_streaming(args, output_fn, timeout, run_opts \\ []) do
    executable = cli_executable()

    case System.find_executable(executable) do
      nil ->
        {:error, :cli_not_found}

      _exe_path ->
        # Wrap via shell to redirect stdin from /dev/null.
        shell_script = ~s(exec "$0" "$@" </dev/null)
        sh_path = System.find_executable("sh")

        cd_opts =
          case Keyword.get(run_opts, :cd) do
            nil -> []
            dir -> [{:cd, to_charlist(dir)}]
          end

        env_opts =
          case build_env() do
            [] -> []
            env -> [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
          end

        sh_args = ["-c", shell_script, executable | args]

        port_opts =
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:line, 65_536},
            {:args, sh_args}
          ] ++
            cd_opts ++ env_opts

        port = Port.open({:spawn_executable, sh_path}, port_opts)
        collect_streaming(port, output_fn, timeout, "", "")
    end
  end

  defp collect_streaming(port, output_fn, timeout, accumulated, line_buffer) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = line_buffer <> line
        accumulated = process_stream_line(full_line, output_fn, accumulated)
        collect_streaming(port, output_fn, timeout, accumulated, "")

      {^port, {:data, {:noeol, partial}}} ->
        collect_streaming(port, output_fn, timeout, accumulated, line_buffer <> partial)

      {^port, {:exit_status, 0}} ->
        {:ok, accumulated}

      {^port, {:exit_status, code}} ->
        Logger.warning(
          "[CursorCLI] exited with code #{code}, output: #{String.slice(accumulated, 0..500)}"
        )

        {:error, {:cli_error, code, accumulated}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp process_stream_line(line, output_fn, accumulated) do
    case Jason.decode(line) do
      # Cursor CLI: assistant message event
      # {"type": "assistant", "message": {"content": [{"type": "text", "text": "..."}]}}
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        text =
          content
          |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
          |> Enum.map_join("", fn part -> Map.get(part, "text", "") end)

        if text != "", do: output_fn.(text)
        accumulated <> text

      # Cursor CLI: result event (no "result" field in stream mode — text accumulated above)
      # {"type": "result", "subtype": "success", "duration_ms": ...}
      {:ok, %{"type" => "result", "subtype" => _}} ->
        accumulated

      # Claude CLI: stream_event wrapper (--include-partial-messages mode)
      {:ok, %{"type" => "stream_event", "event" => event}} ->
        process_stream_event(event, output_fn, accumulated)

      # Claude CLI: bare SSE events
      {:ok, %{"type" => "content_block_delta"} = event} ->
        process_stream_event(event, output_fn, accumulated)

      # Claude CLI: final result with full text
      {:ok, %{"type" => "result", "result" => text}} when is_binary(text) ->
        text

      _ ->
        accumulated
    end
  end

  defp process_stream_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         output_fn,
         accumulated
       )
       when is_binary(text) and text != "" do
    output_fn.(text)
    accumulated <> text
  end

  defp process_stream_event(_event, _output_fn, accumulated), do: accumulated

  # --- JSON Parsing ---

  @doc false
  def parse_json_result(output) do
    trimmed = String.trim(output)

    cond do
      String.starts_with?(trimmed, "[") ->
        parse_json_array(trimmed)

      trimmed != "" ->
        parse_ndjson(trimmed)

      true ->
        {:error, {:parse_error, "empty output"}}
    end
  end

  defp parse_json_array(text) do
    case Jason.decode(text) do
      {:ok, items} when is_list(items) ->
        case find_result(items) do
          nil -> {:error, {:parse_error, text}}
          result -> {:ok, result}
        end

      _ ->
        {:error, {:parse_error, text}}
    end
  end

  defp parse_ndjson(text) do
    result =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(nil, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "result" => result}} when is_binary(result) -> result
          _ -> acc
        end
      end)

    case result do
      nil -> {:error, {:parse_error, text}}
      text -> {:ok, text}
    end
  end

  defp find_result(items) do
    items
    |> Enum.find_value(fn
      %{"type" => "result", "result" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  # --- Helpers ---

  defp build_base_args(model) do
    ["--model", model]
  end

  defp build_env do
    case System.get_env("CURSOR_API_KEY") do
      nil -> []
      key -> [{"CURSOR_API_KEY", key}]
    end
  end

  defp cli_executable do
    Application.get_env(:pyre, :cursor_cli_executable, "cursor-agent")
  end
end
