defmodule Pyre.Plugins.ArtifactTest do
  use ExUnit.Case, async: true

  alias Pyre.Plugins.Artifact

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pyre_art_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "create_run_dir/1" do
    test "creates timestamped directory", %{tmp_dir: tmp_dir} do
      assert {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      assert File.dir?(run_dir)
      assert Path.basename(run_dir) =~ ~r/^\d{8}_\d{6}$/
    end
  end

  describe "write/3 and read/2" do
    test "round-trips content", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      :ok = Artifact.write(run_dir, "test_artifact", "Hello world")
      assert {:ok, "Hello world"} = Artifact.read(run_dir, "test_artifact")
    end

    test "handles .md extension in filename", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      :ok = Artifact.write(run_dir, "test.md", "Content")
      assert {:ok, "Content"} = Artifact.read(run_dir, "test.md")
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:error, :enoent} = Artifact.read(run_dir, "nonexistent")
    end
  end

  describe "latest/2" do
    test "returns only version", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "03_impl", "Content v1")

      assert {:ok, "03_impl.md", "Content v1"} = Artifact.latest(run_dir, "03_impl")
    end

    test "returns highest versioned file", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "03_impl", "Content v1")
      Artifact.write(run_dir, "03_impl_v2", "Content v2")
      Artifact.write(run_dir, "03_impl_v3", "Content v3")

      assert {:ok, "03_impl_v3.md", "Content v3"} = Artifact.latest(run_dir, "03_impl")
    end

    test "returns error when no files match", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:error, :not_found} = Artifact.latest(run_dir, "nonexistent")
    end
  end

  describe "assemble/2" do
    test "concatenates multiple artifacts", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "01_req", "Requirements")
      Artifact.write(run_dir, "02_design", "Design")

      assert {:ok, content} = Artifact.assemble(run_dir, ["01_req.md", "02_design.md"])
      assert content =~ "Requirements"
      assert content =~ "Design"
      assert content =~ "---"
    end

    test "returns empty string for empty list", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:ok, ""} = Artifact.assemble(run_dir, [])
    end

    test "handles missing files", %{tmp_dir: tmp_dir} do
      {:ok, run_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:ok, content} = Artifact.assemble(run_dir, ["missing.md"])
      assert content =~ "(not found)"
    end
  end

  describe "versioned_name/2" do
    test "cycle 1 returns base name" do
      assert Artifact.versioned_name("03_impl", 1) == "03_impl"
    end

    test "cycle 2+ appends version" do
      assert Artifact.versioned_name("03_impl", 2) == "03_impl_v2"
      assert Artifact.versioned_name("03_impl", 3) == "03_impl_v3"
    end
  end
end
