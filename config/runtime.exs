import Config

if config_env() != :test do
  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :req_llm, anthropic_api_key: api_key
  end

  if api_key = System.get_env("OPENAI_API_KEY") do
    config :req_llm, openai_api_key: api_key
  end
end
