# The public API of defk 0.1.0, as data.
#
# This is the surface that docs/guides/stability.md ("The public API")
# promised at the v0.1.0 tag: the documented functions of the public modules
# with their arities (taken from Code.fetch_docs/1 at the tag, minus the
# unstable tier and everything @doc false), the functions `use Defk`
# generates in a kernel module, the options, the configuration key and the
# environment variables.
#
# Frozen: this file is never edited. A later release adds a directory with
# its own file. test/stability_api_test.exs reads it and fails when an item
# listed here is missing, no longer exported, hidden, or has another arity.
# Additions are not listed here, so they pass.
%{
  version: "0.1.0",
  # the public modules, with the promised macros and functions of each
  modules: %{
    # `use Defk` (Elixir hides `__using__` from the docs: the Defk moduledoc
    # describes it) and the `defk` macro in its three forms
    Defk => [
      {:macro, :__using__, 1},
      {:macro, :defk, 1},
      {:macro, :defk, 2},
      {:macro, :defk, 3}
    ],
    Defk.Test => [
      {:function, :assert_agrees, 4},
      {:function, :agreement_reason, 1}
    ],
    Defk.ElixirMode => [
      {:function, :with_mode, 2}
    ],
    # every function of Defk.Bits: each is the meaning of a kernel builtin
    Defk.Bits => [
      {:function, :clz, 1},
      {:function, :clz, 2},
      {:function, :crc32c, 3},
      {:function, :ctz, 1},
      {:function, :ctz, 2},
      {:function, :f64_bits, 1},
      {:function, :mulhi, 2},
      {:function, :popcount, 1},
      {:function, :rotl, 2},
      {:function, :rotl, 3},
      {:function, :rotr, 2},
      {:function, :rotr, 3},
      {:function, :wrap64, 1}
    ],
    # the functions, not their text; the types of Defk.Report are unstable
    Defk.Report => [
      {:function, :print, 1},
      {:function, :format, 1}
    ],
    # the codes in entries/0, not the keys of an entry; fetch!/1 is unstable
    Defk.Errors => [
      {:function, :entries, 0},
      {:function, :explain!, 1}
    ]
  },
  # what `use Defk` defines in a kernel module: a function per kernel with
  # the kernel's name and arity and a @spec, and these two
  generated: [
    {:function, :__defk_elixir__, 2},
    {:function, :__defk_force_yields__, 1}
  ],
  kernel_function: [:exported, :spec],
  # `use Defk, ...`: the option and a value a kernel module accepts
  use_defk_options: [
    elixir_mode: true,
    report: :full,
    max_owned_bytes: 4096
  ],
  # `defk head, ...`: the one kernel option
  kernel_options: [yield: false],
  # the configuration key and the values it accepts
  config: [{:defk, :mode, [:native, :elixir]}],
  # the environment variables, in the elixir_make convention
  env: ["CC", "ERTS_INCLUDE_DIR"]
}
