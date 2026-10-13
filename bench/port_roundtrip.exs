# Out-of-process isolation, measured (defk-7dm): what a port program costs per
# call against a kernel call, by input size. A port (or an erl_interface C
# node) gives real OS-process isolation: a fault, or a wild write that never
# faults, kills only that process. The price is two pipe transfers per call,
# plus term encoding for a C node, which this script does not add: the port
# numbers are the floor of any out-of-process design.
#
#   mix run bench/port_roundtrip.exs
#
# Sides, per input size:
#   kernel   a kernel call that reads the first byte of the binary (the call,
#            the argument check and the return, no work)
#   port ack the same binary to a port program that answers with 8 bytes
#            (one copy in, the reply)
#   port echo ... that answers with the whole binary (one copy each way, as
#            a kernel that returns an output array would)
# Best of five rounds, each round `n` calls, one process, default VM flags.
# Read the load average with the numbers: a shared host makes them provisional.

defmodule PortRoundTrip.K do
  use Defk

  defk first(a :: [u8]) :: i64 do
    if len(a) > 0, do: a[0], else: -1
  end
end

defmodule PortRoundTrip do
  @sizes [{"8 B", 8}, {"1 KB", 1024}, {"64 KB", 65_536}, {"1 MB", 1_048_576}, {"16 MB", 16_777_216}]

  def run do
    exe = Path.join(System.tmp_dir!(), "defk_port_echo")
    {_, 0} = System.cmd("cc", ["-O2", "-o", exe, "bench/port_echo.c"])

    IO.puts("load before: #{load()}")
    IO.puts(String.pad_trailing("size", 8) <> "  kernel        port ack      port echo     (us per call, best of 5)")

    for {label, size} <- @sizes do
      bin = :crypto.strong_rand_bytes(size)
      # the kernel call is zero-copy, so its cost does not grow with the size:
      # many calls for a stable number; the port moves the bytes, so fewer
      n = max(div(50_000_000, size), 20) |> min(20_000)
      nk = 200_000
      ack = open(exe, "ack")
      echo = open(exe, "echo")

      k = best(5, fn -> loop(nk, fn -> PortRoundTrip.K.first(bin) end) end) / nk
      a = best(5, fn -> loop(n, fn -> call(ack, bin) end) end) / n
      e = best(5, fn -> loop(n, fn -> call(echo, bin) end) end) / n

      Port.close(ack)
      Port.close(echo)

      IO.puts(
        String.pad_trailing(label, 8) <>
          "  " <> fmt(k) <> "  " <> fmt(a) <> "  " <> fmt(e) <> "   port ack / kernel: #{Float.round(a / max(k, 0.001), 1)}x"
      )
    end

    IO.puts("load after: #{load()}")
  end

  defp open(exe, mode),
    do: Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :use_stdio, args: [mode]])

  defp call(port, bin) do
    true = Port.command(port, bin)

    receive do
      {^port, {:data, reply}} -> reply
    end
  end

  defp loop(0, _f), do: :ok

  defp loop(n, f) do
    f.()
    loop(n - 1, f)
  end

  # microseconds of the fastest round
  defp best(rounds, f) do
    for _ <- 1..rounds do
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      us
    end
    |> Enum.min()
  end

  defp fmt(us), do: String.pad_leading(:erlang.float_to_binary(us / 1, decimals: 3), 12)

  defp load do
    case System.cmd("uptime", []) do
      {out, 0} -> out |> String.split("load average") |> List.last() |> String.trim()
      _ -> "?"
    end
  end
end

PortRoundTrip.run()
