import Config

if config_env() != :test do
  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :req_llm, anthropic_api_key: api_key
  end

  if api_key = System.get_env("OPENAI_API_KEY") do
    config :req_llm, openai_api_key: api_key
  end

  case System.get_env("PYRE_LLM_BACKEND") do
    "claude_cli" -> config :pyre, :llm_backend, :claude_cli
    "cursor_cli" -> config :pyre, :llm_backend, :cursor_cli
    "codex_cli" -> config :pyre, :llm_backend, :codex_cli
    "req_llm" -> config :pyre, :llm_backend, :req_llm
    _ -> :ok
  end

  if paths = System.get_env("PYRE_ALLOWED_PATHS") do
    config :pyre,
      allowed_paths:
        paths
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Path.expand/1)
  end

  if System.get_env("GITHUB_REPO_URL") do
    config :pyre, :github,
      repositories: [
        [
          url: System.get_env("GITHUB_REPO_URL"),
          token: System.get_env("GITHUB_TOKEN"),
          base_branch: System.get_env("GITHUB_BASE_BRANCH", "main")
        ]
      ]
  end
end
