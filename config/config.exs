import Config

# defk's own test environment only: a project using defk never loads this
# file. The entries exercise the deprecation mechanism (Defk.Deprecations)
# while nothing real is deprecated; test/deprecations_test.exs compiles
# every one of them. The names are invented, so no kernel subset name, `use
# Defk` option, configuration key or function is affected.
if config_env() == :test do
  config :defk,
    deprecations_for_tests: [
      %{kind: :builtin, old: {:legacy_length, 1}, new: {:length, 1}, since: "0.0.0"},
      %{kind: :option, old: :legacy_cap, new: :max_owned_bytes, since: "0.0.0"},
      %{kind: :config, old: :legacy_mode, new: :mode, since: "0.0.0"},
      %{
        kind: :function,
        old: {Defk.DeprecationsTest.Legacy, :old_name, 1},
        new: {Defk.DeprecationsTest.Legacy, :new_name, 1},
        since: "0.0.0"
      }
    ]
end

# Covenant (a dev and test tool): the Contract and its tests share one
# directory, test/contracts/ (README.md there)
config :covenant, contracts_dir: "test/contracts", test_paths: ["test/contracts"]
