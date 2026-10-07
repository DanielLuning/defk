{:ok, _} = Application.ensure_all_started(:logger)
FuzzySearch.Catalog.load()
ExUnit.start(timeout: 600_000)
