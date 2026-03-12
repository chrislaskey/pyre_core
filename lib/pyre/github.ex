defmodule Pyre.GitHub do
  @moduledoc """
  GitHub REST API client using Req.

  ## Configuration

  Configure repositories in your `config/runtime.exs`:

      config :pyre, :github,
        default_token: System.get_env("GITHUB_TOKEN"),
        repositories: [
          [
            owner: System.get_env("PYRE_GITHUB_OWNER"),
            repo: System.get_env("PYRE_GITHUB_REPO"),
            token: System.get_env("PYRE_GITHUB_TOKEN"),
            base_branch: "main"
          ]
        ]

  Library consumers (e.g. a Phoenix app using `pyre` as a dependency) set
  this in their own `runtime.exs`.

  ## Example

      {:ok, config} = Pyre.GitHub.resolve_repo_config("owner", "repo")

      Pyre.GitHub.create_pull_request("owner", "repo", %{
        title: "Add products page",
        body: "Implements CRUD for products.",
        head: "feature/products-page",
        base: "main"
      }, config.token)

  """

  @base_url "https://api.github.com"

  @doc """
  Resolves GitHub configuration for a given owner/repo pair.

  Looks up the `:github` application config for a matching repository entry.
  Falls back to `:default_token` when no repo-specific entry matches.

  Returns `{:ok, %{token: token, base_branch: base_branch}}` or
  `{:error, :token_not_set}`.
  """
  @spec resolve_repo_config(String.t(), String.t()) ::
          {:ok, %{token: String.t(), base_branch: String.t()}} | {:error, :token_not_set}
  def resolve_repo_config(owner, repo) do
    github_config = Application.get_env(:pyre, :github, [])
    repos = Keyword.get(github_config, :repositories, [])

    repo_entry =
      Enum.find(repos, fn entry ->
        Keyword.get(entry, :owner) == owner and Keyword.get(entry, :repo) == repo
      end)

    token =
      if repo_entry do
        Keyword.get(repo_entry, :token) || Keyword.get(github_config, :default_token)
      else
        Keyword.get(github_config, :default_token)
      end

    case token do
      nil ->
        {:error, :token_not_set}

      "" ->
        {:error, :token_not_set}

      t ->
        base_branch =
          if repo_entry,
            do: Keyword.get(repo_entry, :base_branch, "main"),
            else: "main"

        {:ok, %{token: t, base_branch: base_branch}}
    end
  end

  @doc """
  Creates a pull request on GitHub.

  ## Params

    * `:title` — PR title (required)
    * `:body` — PR description markdown (required)
    * `:head` — Branch name to merge from (required)
    * `:base` — Branch name to merge into (default: `"main"`)

  The `token` argument is a GitHub personal access token with `repo` scope.

  Returns `{:ok, %{url: html_url, number: number}}` on success,
  or `{:error, reason}` on failure.
  """
  @spec create_pull_request(String.t(), String.t(), map(), String.t()) ::
          {:ok, %{url: String.t(), number: integer()}} | {:error, term()}
  def create_pull_request(owner, repo, params, token) do
    unless Code.ensure_loaded?(Req) do
      {:error, :req_not_available}
    else
      body = %{
        title: params[:title] || params.title,
        body: params[:body] || params.body,
        head: params[:head] || params.head,
        base: params[:base] || "main"
      }

      case Req.post("#{@base_url}/repos/#{owner}/#{repo}/pulls",
             json: body,
             headers: [
               {"authorization", "Bearer #{token}"},
               {"accept", "application/vnd.github+json"},
               {"x-github-api-version", "2022-11-28"}
             ]
           ) do
        {:ok, %{status: status, body: resp_body}} when status in [201] ->
          {:ok, %{url: resp_body["html_url"], number: resp_body["number"]}}

        {:ok, %{status: 422, body: resp_body}} ->
          message = get_in(resp_body, ["errors", Access.at(0), "message"]) || resp_body["message"]
          {:error, {:validation_error, message}}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:api_error, status, resp_body["message"]}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Parses a GitHub remote URL into `{owner, repo}`.

  Supports both SSH and HTTPS formats:

      iex> Pyre.GitHub.parse_remote_url("git@github.com:owner/repo.git")
      {:ok, {"owner", "repo"}}

      iex> Pyre.GitHub.parse_remote_url("https://github.com/owner/repo.git")
      {:ok, {"owner", "repo"}}

  """
  @spec parse_remote_url(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, :invalid_url}
  def parse_remote_url(url) do
    url = String.trim(url)

    cond do
      # SSH: git@github.com:owner/repo.git
      String.match?(url, ~r{^git@github\.com:}) ->
        path = url |> String.replace(~r{^git@github\.com:}, "") |> String.replace(~r{\.git$}, "")
        parse_owner_repo(path)

      # HTTPS: https://github.com/owner/repo.git
      String.match?(url, ~r{^https?://github\.com/}) ->
        path =
          url |> String.replace(~r{^https?://github\.com/}, "") |> String.replace(~r{\.git$}, "")

        parse_owner_repo(path)

      true ->
        {:error, :invalid_url}
    end
  end

  defp parse_owner_repo(path) do
    case String.split(path, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _ -> {:error, :invalid_url}
    end
  end
end
