Defk.Catalog.load()
Code.require_file("../examples/fuzzy_search/lib/fuzzy_search/kernels.ex", __DIR__)

# :deep - the agreement properties' long runs (mix test --only deep)
# :divergence - properties that find a known divergence, each naming its ticket
# :timing - wall-clock assertions that depend on machine speed/load
#   (mix test --include timing)
# :clang - facts from clang's remarks (the fast-path report's report: :full);
#   excluded when CC is not clang (mix test --only clang runs just these)
clang = if Defk.Build.clang?(), do: [], else: [:clang]
ExUnit.start(exclude: [:deep, :divergence, :timing] ++ clang)
