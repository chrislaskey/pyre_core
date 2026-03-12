import Config

if config_env() != :test do
  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :req_llm, anthropic_api_key: api_key
  end

  if api_key = System.get_env("OPENAI_API_KEY") do
    config :req_llm, openai_api_key: api_key
  end

  if github_token = System.get_env("GITHUB_TOKEN") do
    config :pyre, :github,
      default_token: github_token,
      repositories:
        if(System.get_env("PYRE_GITHUB_OWNER"),
          do: [
            [
              owner: System.get_env("PYRE_GITHUB_OWNER"),
              repo: System.get_env("PYRE_GITHUB_REPO"),
              token: System.get_env("PYRE_GITHUB_TOKEN", github_token),
              base_branch: System.get_env("PYRE_GITHUB_BASE_BRANCH", "main")
            ]
          ],
          else: []
        )
  end
end
