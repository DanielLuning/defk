defmodule Defk.NoConflictMarkersTest do
  use ExUnit.Case, async: true

  # Merge conflict markers reached main twice on 2026-10-09 in docs that no
  # other test reads line by line. Every tracked text file is checked.
  test "no file carries git conflict markers" do
    {out, 0} =
      System.cmd("git", [
        "ls-files",
        "--",
        "docs",
        "examples",
        "lib",
        "test",
        "priv",
        "bench",
        "*.md",
        "*.exs"
      ])

    offenders =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(fn path ->
        File.regular?(path) and
          path
          |> File.stream!()
          |> Enum.any?(
            &(String.starts_with?(&1, "<<<<<<< ") or String.starts_with?(&1, ">>>>>>> "))
          )
      end)

    assert offenders == [], "conflict markers in: #{Enum.join(offenders, ", ")}"
  end
end
