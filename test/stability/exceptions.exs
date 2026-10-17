# The exceptions to the frozen files, live: the frozen files and the frozen
# contract tests of test/stability/<version>/ are never edited, so what a
# later release changed on purpose is listed here, and every contract test,
# frozen or not, reads it through Defk.ContractKit.exceptions/1. The lists
# only grow: an entry stays for as long as its file does. Each entry is
# `{file, words}`, the file relative to test/stability/ and words that the
# CHANGELOG entry naming the change contains. docs/agents/stability.md has
# the rules.
%{
  # A frozen kernel whose recorded result or acceptance a bug fix changed,
  # named in the CHANGELOG. The example must then keep failing. None yet.
  fixed: [],
  # A frozen rejection that compiles now because a minor release made the
  # construct valid while its code stays active for other constructs (a code
  # that covers nothing else is retired instead, in the registry). The
  # example must then compile.
  newly_supported: [
    # Enum.reduce/3 became a kernel form; enum-reduce still rejects Enum.reduce/2
    {"0.1.0/rejections/lib-defk-errors-enum-reduce.md", "Added: `Enum.reduce/3` in kernels"},
    # a raise message may interpolate integers; raise-message still rejects other values
    {"0.1.0/rejections/lib-defk-errors-raise-message.md",
     "a kernel's `raise` message may interpolate integer values"}
  ]
}
