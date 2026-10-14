%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {ExSlop.Check.Readability.NarratorDoc, false},
        # the compiler is one huge decision table; the complexity beyond 15
        # (or nesting beyond 3) that it had has been decomposed.
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
        {Credo.Check.Refactor.Nesting, [max_nesting: 3]}
      ]
    }
  ]
}
