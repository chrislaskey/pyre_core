defmodule Pyre.SessionTest do
  use ExUnit.Case, async: true

  alias Pyre.Session

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  describe "generate_id/0" do
    test "returns a valid RFC 4122 v4 UUID" do
      uuid = Session.generate_id()
      assert String.match?(uuid, @uuid_regex), "Expected UUID format, got: #{uuid}"
    end

    test "returns a string of length 36" do
      assert String.length(Session.generate_id()) == 36
    end

    test "returns unique values on repeated calls" do
      uuids = Enum.map(1..20, fn _ -> Session.generate_id() end)
      assert length(Enum.uniq(uuids)) == 20
    end
  end

  describe "generate_for_stages/1" do
    test "returns a map with one UUID per stage" do
      stages = [:planning, :designing, :architecting]
      result = Session.generate_for_stages(stages)

      assert map_size(result) == 3
      assert Map.has_key?(result, :planning)
      assert Map.has_key?(result, :designing)
      assert Map.has_key?(result, :architecting)
    end

    test "each value is a valid UUID" do
      result = Session.generate_for_stages([:planning, :designing])

      Enum.each(result, fn {_stage, uuid} ->
        assert String.match?(uuid, @uuid_regex)
      end)
    end

    test "generates unique UUIDs across all stages" do
      result = Session.generate_for_stages([:planning, :designing, :implementing])
      uuids = Map.values(result)
      assert length(uuids) == length(Enum.uniq(uuids))
    end

    test "handles empty stage list" do
      assert Session.generate_for_stages([]) == %{}
    end
  end
end
