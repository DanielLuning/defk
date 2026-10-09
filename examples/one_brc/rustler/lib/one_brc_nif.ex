defmodule OneBrc.Nif do
  @moduledoc """
  The 1BRC per-chunk aggregate as a Rustler NIF, in two scheduler flavours.
  `aggregate(chunk)` takes a newline-aligned chunk (whole `<name>;<temp>\\n`
  lines) and returns a list of `{name, min, max, sum, count}` with the
  temperatures as integer tenths.
  """
  use Rustler, otp_app: :one_brc_rustler, crate: "one_brc_nif", mode: :release

  # plain NIF: runs on a normal scheduler for the whole call
  def aggregate(_chunk), do: :erlang.nif_error(:nif_not_loaded)
  # the same function with schedule = "DirtyCpu"
  def aggregate_dirty(_chunk), do: :erlang.nif_error(:nif_not_loaded)
end
