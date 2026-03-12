defmodule Pyre.GitHubTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:pyre, :github) end)
  end

  describe "resolve_repo_config/2" do
    test "finds matching repository entry" do
      Application.put_env(:pyre, :github,
        default_token: "default-tok",
        repositories: [
          [owner: "acme", repo: "app", token: "repo-tok", base_branch: "develop"]
        ]
      )

      assert {:ok, %{token: "repo-tok", base_branch: "develop"}} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "falls back to default_token when no repo matches" do
      Application.put_env(:pyre, :github,
        default_token: "fallback-tok",
        repositories: [
          [owner: "other", repo: "thing", token: "other-tok"]
        ]
      )

      assert {:ok, %{token: "fallback-tok", base_branch: "main"}} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "uses default_token when repo entry has no token" do
      Application.put_env(:pyre, :github,
        default_token: "default-tok",
        repositories: [
          [owner: "acme", repo: "app", base_branch: "develop"]
        ]
      )

      assert {:ok, %{token: "default-tok", base_branch: "develop"}} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "returns error when no token is available" do
      Application.put_env(:pyre, :github, repositories: [])

      assert {:error, :token_not_set} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "returns error when config is empty" do
      Application.put_env(:pyre, :github, [])

      assert {:error, :token_not_set} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "returns error when no config is set" do
      Application.delete_env(:pyre, :github)

      assert {:error, :token_not_set} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "defaults base_branch to main for matching entry without it" do
      Application.put_env(:pyre, :github,
        repositories: [
          [owner: "acme", repo: "app", token: "tok"]
        ]
      )

      assert {:ok, %{token: "tok", base_branch: "main"}} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end

    test "matches first repository in list" do
      Application.put_env(:pyre, :github,
        repositories: [
          [owner: "acme", repo: "app", token: "first-tok", base_branch: "main"],
          [owner: "acme", repo: "app", token: "second-tok", base_branch: "develop"]
        ]
      )

      assert {:ok, %{token: "first-tok", base_branch: "main"}} =
               Pyre.GitHub.resolve_repo_config("acme", "app")
    end
  end

  describe "parse_remote_url/1" do
    test "parses SSH URLs" do
      assert {:ok, {"owner", "repo"}} =
               Pyre.GitHub.parse_remote_url("git@github.com:owner/repo.git")
    end

    test "parses HTTPS URLs" do
      assert {:ok, {"owner", "repo"}} =
               Pyre.GitHub.parse_remote_url("https://github.com/owner/repo.git")
    end

    test "handles URLs without .git suffix" do
      assert {:ok, {"owner", "repo"}} =
               Pyre.GitHub.parse_remote_url("https://github.com/owner/repo")
    end

    test "returns error for invalid URLs" do
      assert {:error, :invalid_url} = Pyre.GitHub.parse_remote_url("not-a-url")
    end
  end
end
