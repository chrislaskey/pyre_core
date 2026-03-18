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
    test "creates timestamped directory with default feature", %{tmp_dir: tmp_dir} do
      assert {:ok, run_dir, feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert File.dir?(run_dir)
      assert File.dir?(feature_dir)
      # run_dir is feature_dir/timestamp
      assert Path.dirname(run_dir) == feature_dir
      assert Path.basename(run_dir) =~ ~r/^\d{8}_\d{6}$/
      # feature_dir name is the timestamp (default when no name given)
      assert Path.basename(feature_dir) =~ ~r/^\d{8}_\d{6}$/
    end
  end

  describe "create_run_dir/2" do
    test "creates feature directory with slugified name", %{tmp_dir: tmp_dir} do
      assert {:ok, run_dir, feature_dir} = Artifact.create_run_dir(tmp_dir, "My Cool Feature")
      assert File.dir?(run_dir)
      assert File.dir?(feature_dir)
      assert Path.basename(feature_dir) == "my-cool-feature"
      assert Path.dirname(run_dir) == feature_dir
      assert Path.basename(run_dir) =~ ~r/^\d{8}_\d{6}$/
    end

    test "uses timestamp as feature when nil", %{tmp_dir: tmp_dir} do
      assert {:ok, _run_dir, feature_dir} = Artifact.create_run_dir(tmp_dir, nil)
      assert Path.basename(feature_dir) =~ ~r/^\d{8}_\d{6}$/
    end

    test "uses timestamp as feature when empty string", %{tmp_dir: tmp_dir} do
      assert {:ok, _run_dir, feature_dir} = Artifact.create_run_dir(tmp_dir, "")
      assert Path.basename(feature_dir) =~ ~r/^\d{8}_\d{6}$/
    end

    test "creates sibling runs under same feature", %{tmp_dir: tmp_dir} do
      {:ok, run_dir1, feature_dir1} = Artifact.create_run_dir(tmp_dir, "my-feature")
      Process.sleep(1100)
      {:ok, run_dir2, feature_dir2} = Artifact.create_run_dir(tmp_dir, "my-feature")

      assert feature_dir1 == feature_dir2
      assert run_dir1 != run_dir2
      assert Path.dirname(run_dir1) == Path.dirname(run_dir2)
    end
  end

  describe "write/3 and read/2" do
    test "round-trips content", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      :ok = Artifact.write(run_dir, "test_artifact", "Hello world")
      assert {:ok, "Hello world"} = Artifact.read(run_dir, "test_artifact")
    end

    test "handles .md extension in filename", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      :ok = Artifact.write(run_dir, "test.md", "Content")
      assert {:ok, "Content"} = Artifact.read(run_dir, "test.md")
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:error, :enoent} = Artifact.read(run_dir, "nonexistent")
    end
  end

  describe "latest/2" do
    test "returns only version", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "03_impl", "Content v1")

      assert {:ok, "03_impl.md", "Content v1"} = Artifact.latest(run_dir, "03_impl")
    end

    test "returns highest versioned file", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "03_impl", "Content v1")
      Artifact.write(run_dir, "03_impl_v2", "Content v2")
      Artifact.write(run_dir, "03_impl_v3", "Content v3")

      assert {:ok, "03_impl_v3.md", "Content v3"} = Artifact.latest(run_dir, "03_impl")
    end

    test "returns error when no files match", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:error, :not_found} = Artifact.latest(run_dir, "nonexistent")
    end
  end

  describe "assemble/2" do
    test "concatenates multiple artifacts", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "01_req", "Requirements")
      Artifact.write(run_dir, "02_design", "Design")

      assert {:ok, content} = Artifact.assemble(run_dir, ["01_req.md", "02_design.md"])
      assert content =~ "Requirements"
      assert content =~ "Design"
      assert content =~ "---"
    end

    test "returns empty string for empty list", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:ok, ""} = Artifact.assemble(run_dir, [])
    end

    test "handles missing files", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert {:ok, content} = Artifact.assemble(run_dir, ["missing.md"])
      assert content =~ "(not found)"
    end
  end

  describe "store_attachments/2 and read_attachments/1" do
    test "round-trips attachment files", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)

      attachments = [
        %{filename: "spec.md", content: "# Spec\nDetails here"},
        %{filename: "data.csv", content: "a,b,c\n1,2,3"}
      ]

      assert :ok = Artifact.store_attachments(run_dir, attachments)

      result = Artifact.read_attachments(run_dir)
      assert length(result) == 2
      assert Enum.find(result, &(&1.filename == "spec.md")).content == "# Spec\nDetails here"
      assert Enum.find(result, &(&1.filename == "data.csv")).media_type == "text/csv"
    end

    test "returns empty list when no prompt dir exists", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert Artifact.read_attachments(run_dir) == []
    end

    test "store_attachments with empty list is a no-op", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _feature_dir} = Artifact.create_run_dir(tmp_dir)
      assert :ok = Artifact.store_attachments(run_dir, [])
      refute File.dir?(Path.join(run_dir, "prompt"))
    end
  end

  describe "media_type_from_filename/1" do
    test "classifies text files" do
      assert Artifact.media_type_from_filename("readme.md") == "text/markdown"
      assert Artifact.media_type_from_filename("notes.txt") == "text/plain"
      assert Artifact.media_type_from_filename("data.csv") == "text/csv"
      assert Artifact.media_type_from_filename("app.ex") == "text/x-elixir"
      assert Artifact.media_type_from_filename("config.json") == "application/json"
    end

    test "classifies image files" do
      assert Artifact.media_type_from_filename("mockup.png") == "image/png"
      assert Artifact.media_type_from_filename("photo.jpg") == "image/jpeg"
      assert Artifact.media_type_from_filename("photo.jpeg") == "image/jpeg"
      assert Artifact.media_type_from_filename("anim.gif") == "image/gif"
      assert Artifact.media_type_from_filename("modern.webp") == "image/webp"
    end

    test "returns octet-stream for unknown extensions" do
      assert Artifact.media_type_from_filename("file.xyz") == "application/octet-stream"
    end
  end

  describe "text_attachment?/1 and image_attachment?/1" do
    test "text_attachment? returns true for text types" do
      assert Artifact.text_attachment?(%{media_type: "text/markdown"})
      assert Artifact.text_attachment?(%{media_type: "text/plain"})
      assert Artifact.text_attachment?(%{media_type: "application/json"})
    end

    test "text_attachment? returns false for non-text types" do
      refute Artifact.text_attachment?(%{media_type: "image/png"})
      refute Artifact.text_attachment?(%{media_type: "application/octet-stream"})
    end

    test "image_attachment? returns true for image types" do
      assert Artifact.image_attachment?(%{media_type: "image/png"})
      assert Artifact.image_attachment?(%{media_type: "image/jpeg"})
    end

    test "image_attachment? returns false for non-image types" do
      refute Artifact.image_attachment?(%{media_type: "text/plain"})
    end
  end

  describe "prior_runs/1" do
    test "lists timestamp dirs newest first", %{tmp_dir: tmp_dir} do
      feature_dir = Path.join(tmp_dir, "my-feature")
      File.mkdir_p!(Path.join(feature_dir, "20260101_120000"))
      File.mkdir_p!(Path.join(feature_dir, "20260102_120000"))
      File.mkdir_p!(Path.join(feature_dir, "20260103_120000"))

      assert Artifact.prior_runs(feature_dir) == [
               "20260103_120000",
               "20260102_120000",
               "20260101_120000"
             ]
    end

    test "excludes non-timestamp entries", %{tmp_dir: tmp_dir} do
      feature_dir = Path.join(tmp_dir, "my-feature")
      File.mkdir_p!(Path.join(feature_dir, "20260101_120000"))
      File.mkdir_p!(Path.join(feature_dir, "prompt"))
      File.write!(Path.join(feature_dir, "notes.md"), "hello")

      assert Artifact.prior_runs(feature_dir) == ["20260101_120000"]
    end

    test "returns empty list for nonexistent dir", %{tmp_dir: tmp_dir} do
      assert Artifact.prior_runs(Path.join(tmp_dir, "nonexistent")) == []
    end
  end

  describe "list_artifacts/1" do
    test "lists .md files sorted", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _} = Artifact.create_run_dir(tmp_dir)
      Artifact.write(run_dir, "02_design", "Design")
      Artifact.write(run_dir, "01_req", "Requirements")
      File.write!(Path.join(run_dir, "notes.txt"), "not an artifact")

      assert Artifact.list_artifacts(run_dir) == ["01_req.md", "02_design.md"]
    end

    test "returns empty list for empty dir", %{tmp_dir: tmp_dir} do
      {:ok, run_dir, _} = Artifact.create_run_dir(tmp_dir)
      assert Artifact.list_artifacts(run_dir) == []
    end
  end

  describe "list_features/1" do
    test "lists feature directories", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "alpha-feature"))
      File.mkdir_p!(Path.join(tmp_dir, "beta-feature"))
      # timestamp-only dirs are excluded
      File.mkdir_p!(Path.join(tmp_dir, "20260101_120000"))

      assert Artifact.list_features(tmp_dir) == ["alpha-feature", "beta-feature"]
    end

    test "returns empty list when no features exist", %{tmp_dir: tmp_dir} do
      assert Artifact.list_features(tmp_dir) == []
    end

    test "returns empty list for nonexistent dir", %{tmp_dir: tmp_dir} do
      assert Artifact.list_features(Path.join(tmp_dir, "nonexistent")) == []
    end
  end

  describe "slugify/1" do
    test "lowercases and replaces spaces" do
      assert Artifact.slugify("My Cool Feature") == "my-cool-feature"
    end

    test "handles special characters" do
      assert Artifact.slugify("Feature #1: The Beginning!") == "feature-1-the-beginning"
    end

    test "collapses consecutive hyphens" do
      assert Artifact.slugify("hello---world") == "hello-world"
    end

    test "trims leading and trailing hyphens" do
      assert Artifact.slugify("--hello--") == "hello"
    end

    test "handles already-slugified input" do
      assert Artifact.slugify("products-page") == "products-page"
    end

    test "returns empty string for all-special input" do
      assert Artifact.slugify("!!!") == ""
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
