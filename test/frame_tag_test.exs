# Frame layout tag (defk-ls8), defence in depth. A promoted frame carries a tag
# (hash of priv/defk_runtime.h + sizeof defk_ctx) and its struct size; the step
# function checks both once at entry, and the destructor skips its cleanup on a
# mismatch. Frames of different libraries never meet (defk-nbl), so a foreign
# frame cannot be built from Elixir: __defk_corrupt_tags__/1 makes
# defk_promote stamp a wrong tag, which is exactly what a frame of another
# layout looks like to the step function and the destructor.

defmodule Defk.FrameTagTest.K do
  use Defk

  # an owned buffer, and a nested loop so every iteration has a safepoint
  # (under forced yields the frame is promoted on the first one)
  defk sum(n :: i64) :: i64 do
    buf = alloc(i64, 1024)

    for i <- 1..n//1, reduce: 0 do
      acc ->
        for j <- 0..3//1 do
          buf[j] = i
        end

        acc + buf[0]
    end
  end
end

defmodule Defk.FrameTagTest do
  use ExUnit.Case, async: false

  alias Defk.FrameTagTest.K

  # The frames of a rejected resume are never reclaimed by the destructor (it
  # skips them, leaving frames_live alone), so assert on deltas.
  defp live, do: K.__defk_stats__().frames_live

  # a frame's destructor runs once the process that held its term is collected
  defp settle(want, tries \\ 100) do
    :erlang.garbage_collect()
    got = live()

    cond do
      got == want -> got
      tries == 0 -> got
      true -> Process.sleep(10) && settle(want, tries - 1)
    end
  end

  test "the tag is emitted and checked at step entry" do
    src = K.__defk_source__()
    assert src =~ ~r/#define DEFK_HEADER_HASH \d+ULL/
    assert src =~ "defk_get_frame(env, argv[0], sizeof *F, &exc)"
  end

  test "normal resume passes the tag check" do
    live0 = live()
    K.__defk_force_yields__(true)

    try do
      assert K.sum(100) == 5050
    after
      K.__defk_force_yields__(false)
    end

    assert settle(live0) == live0
    assert K.__defk_stats__().promotions > 0
  end

  test "a frame with a foreign tag fails cleanly in the step function and the destructor" do
    live0 = live()
    K.__defk_force_yields__(true)
    K.__defk_corrupt_tags__(true)

    try do
      # raised from the first resume, before the frame is read
      for _ <- 1..20 do
        assert_raise ArgumentError, ~r/foreign layout/, fn -> K.sum(100) end
      end

      # let the destructors run on the rejected frames: they must not crash
      settle(live0 + 20)
    after
      K.__defk_corrupt_tags__(false)
      K.__defk_force_yields__(false)
    end

    # the destructor left the foreign frames alone: no cleanup, no counter
    assert settle(live0 + 20) == live0 + 20

    # the VM is alive and untampered frames work again
    assert K.sum(10) == 55
    K.__defk_force_yields__(true)

    try do
      assert K.sum(10) == 55
    after
      K.__defk_force_yields__(false)
    end
  end
end
