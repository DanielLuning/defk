defmodule Defk.ExamplesTaskTest do
  # `mix defk.examples`: the selection and the check-only mode of
  # Defk.Bench.report/1. The examples themselves are not run here (that is the
  # task's job, outside mix ci).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Defk.TestKit, only: [defk_result: 1, restore_env_on_exit: 1]

  alias Defk.Examples

  describe "selection" do
    test "by default the examples outside mix test, plus the app's tests" do
      {:ok, {examples, app?}} = Examples.select(nil, false)
      assert app?
      assert "keccak" in examples
      assert "out_of_scope_word_count" in examples
      assert Examples.in_mix_test() -- examples == Examples.in_mix_test()
      refute "_template" in examples
    end

    test "--all adds the examples mix test covers" do
      {:ok, {examples, _}} = Examples.select(nil, true)
      assert Examples.in_mix_test() -- examples == []
    end

    test "--only names examples, and the app by name; unknown names are an error" do
      assert {:ok, {["hashes", "keccak"], false}} = Examples.select(["keccak", "hashes"], false)
      assert {:ok, {[], true}} = Examples.select(["fuzzy_search"], false)
      assert {:error, message} = Examples.select(["nope"], false)
      assert message =~ "nope"
    end

    test "every catalog script is an example" do
      assert Examples.in_mix_test() -- Examples.all() == []
    end
  end

  describe "check-only mode" do
    setup do
      restore_env_on_exit(["DEFK_CHECK_ONLY"])
      System.put_env("DEFK_CHECK_ONLY", "1")
    end

    defp report(opts) do
      parent = self()

      out =
        capture_io(fn -> send(parent, {:r, Defk.Bench.report(opts)}) end)

      assert_received {:r, r}
      {r, out, defk_result(out)}
    end

    defp boom, do: fn -> flunk("timed in check-only mode") end

    test "runs the check, times nothing, has no verdict" do
      {r, out, json} =
        report(
          name: "t",
          expected: :good,
          elixir: boom(),
          defk: boom(),
          check: fn -> true end,
          sweep: {[1], fn _ -> {boom(), boom()} end},
          responsiveness: true
        )

      assert r.correct == true
      assert r.verdict == :good
      assert json["check_only"] == true
      assert json["verdict"] == nil
      refute Map.has_key?(json, "sweep")
      assert out =~ "check only"
    end

    test "a failing check is reported as correct: false" do
      {r, _out, json} =
        report(name: "t", expected: :good, elixir: boom(), defk: boom(), check: fn -> false end)

      assert r.correct == false
      assert json["correct"] == false
    end

    test "check: :none stays visible, and an out_of_scope example (no :defk) passes" do
      {_r, _out, json} =
        report(
          name: "t",
          expected: :good,
          elixir: boom(),
          defk: boom(),
          check: :none,
          reason: "why"
        )

      assert json["correct"] == "skipped"

      {_r, _out, json} = report(name: "t", expected: :out_of_scope, elixir: boom(), reason: "no")
      assert json["correct"] == true
    end

    test "the same argument validation as a timed report" do
      assert_raise ArgumentError, ~r/:check is required/, fn ->
        report(name: "t", expected: :good, elixir: boom(), defk: boom())
      end
    end
  end

  test "parse_results reads every DEFK_RESULT line and skips garbage" do
    out =
      ~s(noise\nDEFK_RESULT {"example":"a","correct":true}\nDEFK_RESULT not json\nDEFK_RESULT {"example":"b"}\n)

    assert [%{"example" => "a"}, %{"example" => "b"}] = Examples.parse_results(out)
  end
end
