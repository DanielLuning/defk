defmodule Defk.Test.Frames do
  @moduledoc false
  # frames_live counts frame resources, which are freed by the resource
  # destructor: when the owning term is garbage collected or its process dies
  # (the kernel's owned buffers are freed earlier and synchronously, by
  # defk_finish on a raise or a normal end). The destructor can run on another
  # scheduler a moment after control is back in the test, so a strict read
  # right after a raise, a kill or a finish is racy under load.
  # Poll with a bounded timeout instead.

  import ExUnit.Assertions

  @doc """
  Asserts that library `mod` has `expected` live frames (default 0), waiting up
  to `timeout` ms for the destructors to run. Collects this process's garbage
  while polling, since it may hold the last reference to a finished frame.
  """
  def assert_frames_live(mod, expected \\ 0, timeout \\ 30_000) do
    await(mod, expected, System.monotonic_time(:millisecond) + timeout)
  end

  defp await(mod, expected, deadline) do
    case mod.__defk_stats__() do
      %{frames_live: ^expected} = stats ->
        stats

      stats ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("frames_live stayed #{stats.frames_live}, expected #{expected}")
        else
          :erlang.garbage_collect()
          Process.sleep(1)
          await(mod, expected, deadline)
        end
    end
  end
end
