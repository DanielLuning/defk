# Deprecations: how to rename a promised name

The stability promise (`docs/guides/stability.md`, "How a change is made"):
an old name keeps working until the next major version, with a compile-time
warning that names the replacement, and `CHANGELOG.md` lists it. The
mechanism is `Defk.Deprecations` (`lib/defk/deprecations.ex`): one table of
entries `%{kind:, old:, new:, since:}`, and the renames it drives. The
module is `@moduledoc false`: the table is a maintainer's tool, and the
warning text is not a promised surface.

## Renaming a name

1. Make the new name work: add the builtin, option, key or function under
   its new name, as for any addition.
2. Add an entry to `@released` in `Defk.Deprecations`, with `since` set to
   the release that makes the rename:

   | kind | `old` and `new` | what happens |
   |---|---|---|
   | `:builtin` | `{name, arity}` | `rename_builtins/2` renames each call in `__before_compile__`, before the compiler and Elixir mode see the kernel, so both lower the new builtin. A kernel the module defines under the old name is called as before. |
   | `:option` | the `use Defk` key | `rename_options/2` renames the key in `__using__`. |
   | `:config` | the `config :defk` key | `compile_env/2` reads the old key when the new one is unset. |
   | `:function` | `{module, name, arity}` | nothing: write the old function as `@deprecated "Use new/arity instead"` plus `defdelegate` to the new one, and Elixir warns at each call. The entry records the rename for the test. |

   Each use site warns once per compile with `IO.warn` at the use site's
   file and line. An entry may not rename to a name that another entry
   deprecates (the module refuses to compile).
3. Extend `test/deprecations_test.exs`: give the entry a source in
   `@builtins`, `@options` or `@configs` (the test fails until every entry
   has one), and a function entry its `@deprecated` delegate.
4. Add the rename to `CHANGELOG.md` under "Unreleased", and update the
   docs that name the old name.
5. In the next major version: remove the entry, the old function and the
   test source, and list the removal in `CHANGELOG.md`.

## The test entries

`config/config.exs` sets `config :defk, deprecations_for_tests:` in defk's
`:test` environment only; a project using defk never loads that file. The
entries use invented names (`legacy_length/1`, `legacy_cap:`,
`legacy_mode:`, `Defk.DeprecationsTest.Legacy.old_name/1`), so no real
name is affected, and `test/deprecations_test.exs` compiles every one of
them and asserts on the warning text and location. The real table may stay
empty: the test still exercises every kind.
