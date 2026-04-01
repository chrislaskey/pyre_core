defmodule Pyre.GitHub.App do
  @moduledoc """
  GitHub App JWT generation and installation token management.

  ## Configuration

      config :pyre, :github_apps, [
        [
          app_id: "123456",
          private_key: "-----BEGIN RSA PRIVATE KEY-----\\n...",
          webhook_secret: "whsec_...",
          bot_slug: "pyre-code-review"
        ]
      ]
  """

  @token_refresh_buffer_seconds 300

  @doc """
  Returns true if GitHub App credentials are configured.
  """
  def configured? do
    config = app_config()
    config[:app_id] != nil and config[:private_key] != nil
  end

  @doc """
  Returns the bot slug used for @mention detection.
  """
  def bot_slug do
    app_config()[:bot_slug]
  end

  @doc """
  Returns the webhook secret for HMAC verification.
  """
  def webhook_secret do
    app_config()[:webhook_secret]
  end

  @doc """
  Returns a valid installation access token, refreshing if needed.

  Caches tokens in ETS. Tokens expire after 1 hour; we refresh
  5 minutes before expiry.
  """
  def installation_token(installation_id) do
    ensure_cache_table()

    case :ets.lookup(__MODULE__, {:token, installation_id}) do
      [{_, token, expires_at}] ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, token}
        else
          refresh_installation_token(installation_id)
        end

      [] ->
        refresh_installation_token(installation_id)
    end
  end

  @doc """
  Generates a JWT for authenticating as the GitHub App itself.

  The JWT is signed with RS256 using the App's private key.
  Valid for 10 minutes (GitHub maximum).
  """
  def generate_jwt do
    config = app_config()
    app_id = config[:app_id]
    private_key_pem = config[:private_key]

    now = DateTime.utc_now() |> DateTime.to_unix()

    claims = %{
      "iss" => app_id,
      "iat" => now - 60,
      "exp" => now + 10 * 60
    }

    jwk = JOSE.JWK.from_pem(private_key_pem)
    jws = %{"alg" => "RS256"}

    {_, compact} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    compact
  end

  # --- Private ---

  defp refresh_installation_token(installation_id) do
    jwt = generate_jwt()

    case Req.post(
           "https://api.github.com/app/installations/#{installation_id}/access_tokens",
           headers: [
             {"authorization", "Bearer #{jwt}"},
             {"accept", "application/vnd.github+json"}
           ]
         ) do
      {:ok, %{status: 201, body: body}} ->
        token = body["token"]
        {:ok, expires_at, _} = DateTime.from_iso8601(body["expires_at"])
        buffered_expiry = DateTime.add(expires_at, -@token_refresh_buffer_seconds, :second)
        :ets.insert(__MODULE__, {{:token, installation_id}, token, buffered_expiry})
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body["message"]}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp ensure_cache_table do
    if :ets.whereis(__MODULE__) == :undefined do
      :ets.new(__MODULE__, [:named_table, :public, :set])
    end
  end

  defp app_config do
    Application.get_env(:pyre, :github_apps, []) |> List.first([])
  end
end
