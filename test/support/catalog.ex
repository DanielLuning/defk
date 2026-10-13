defmodule Defk.Catalog do
  @moduledoc false
  # The catalog's kernels live in example scripts that also install deps and
  # run a benchmark; load compiles only the modules named here, never "every
  # defmodule" (a helper such as Cosine.NxSearch needs a Mix.install dep and
  # would not compile). Each script lists its kernel module (and the Elixir
  # version a test compares it with, where one does), in definition order.
  # The choice is in examples/README.md ("Examples in mix test"). test_helper.exs
  # calls load once, before any test file is loaded.
  #
  # The scripts compile in parallel (their modules do not depend on each
  # other); the modules of one script compile in order.

  @scripts [
    geo_nearest: [Geo.Kernels, Geo.Elixir],
    rolling_stats: [Rolling.Kernels, Rolling.Elixir],
    image_blur: [Blur.Kernels, Blur.Elixir],
    gorilla_encode: [Gorilla.Kernels],
    lz4_snappy_decode: [LzSnappy.Kernels],
    # Hashes.CRC32CPortable is the same kernels again, for the table fallback
    hashes: [Hashes.CRC32CTables, Hashes.CRC32CKernels, Hashes.Kernels],
    hll_update_many: [Hll.Kernels],
    # Cosine.NxSearch needs Nx
    cosine_topk: [Cosine.Kernels]
  ]

  def load do
    @scripts
    |> Task.async_stream(&load_script/1, ordered: false, timeout: :infinity)
    |> Stream.run()
  end

  defp load_script({name, modules}) do
    file = Path.expand("../../examples/#{name}.exs", __DIR__)
    {:__block__, _, top} = Code.string_to_quoted!(File.read!(file), file: file)

    defs =
      for {:defmodule, _, [{:__aliases__, _, parts} | _]} = mod <- top,
          do: {Module.concat(parts), mod}

    for module <- modules do
      {^module, quoted} =
        List.keyfind(defs, module, 0) || raise "#{name}.exs defines no #{inspect(module)}"

      Code.compile_quoted(quoted, file)
    end

    :ok
  end
end
