defmodule Defk.CompileErrorsTest do
  # Every error code's example is rejected with that code, and its rewrite
  # compiles (Defk.Errors.codes/0). Also: the format of a compile error, the
  # targeted hints for first-write forms, and collecting every rejection in a
  # module without the errors an earlier one causes.
  use ExUnit.Case, async: true

  import Defk.TestKit

  # the examples and rewrites of every code, compiled concurrently (a
  # distinct key each, so no two tasks compile one module):
  # %{code => {example_result, rewrite_result}}
  setup_all do
    results =
      Defk.Errors.codes()
      |> Enum.filter(& &1.example)
      |> Task.async_stream(
        fn e ->
          {e.code,
           {compile(__MODULE__, e.example, key: {e.code, :example}),
            compile(__MODULE__, e.rewrite, key: {e.code, :rewrite})}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{results: results}
  end

  # permanent and planned in words
  defp assert_kind(:subset, what), do: assert(what =~ "not in the kernel subset")
  defp assert_kind(:planned, what), do: assert(what =~ "not supported yet")

  defp assert_kind(:error, what),
    do: refute(what =~ ~r/not in the kernel subset|not supported yet/)

  describe "every code" do
    # Codes with `example: nil` come from the build environment, not from kernel
    # source (no-c-compiler), so no module body triggers them; test/build_test.exs
    # covers them.
    for %{code: code} <- Defk.Errors.codes(), Defk.Errors.fetch!(code).example do
      @code code
      test "#{code}: the example is rejected with it and the rewrite compiles", %{
        results: results
      } do
        %{kind: kind} = Defk.Errors.fetch!(@code)
        {msg, rewrite} = Map.fetch!(results, @code)
        assert is_binary(msg), "the example for #{@code} compiled"
        assert codes(msg) == [@code], msg
        [what] = whats(msg)
        assert_kind(kind, what)
        refute msg =~ ~r/defk-[a-z0-9]{3}/, "a ticket ID in #{msg}"
        assert rewrite == :ok, "the rewrite for #{@code} does not compile:\n#{rewrite}"
      end
    end

    # the slug form of a code: test/compile_errors_doc_test.exs
    test "codes are unique, with a kind, summary, why and hint" do
      codes = Enum.map(Defk.Errors.codes(), & &1.code)
      assert codes == Enum.uniq(codes)

      for e <- Defk.Errors.codes() do
        assert e.kind in [:subset, :planned, :error]

        for k <- [:summary, :why, :hint],
            do: assert(is_binary(Map.fetch!(e, k)) and e[k] != "", "#{e.code} #{k}")
      end
    end

    # Every code literal in lib/ is in the registry, and every registry code
    # is used somewhere in lib/. Not errors.ex: it defines every code, so it
    # would make the second half pass for any code. Not test.ex: its strings
    # are message fragments ("non-finite"), not codes. err! checks its own
    # literal codes when the compiler compiles (Errors.validate_code!/1); the
    # rewrites, clauses, raise and diagnostics modules pass theirs as data.
    test "every code literal in lib/ is in the registry, and every registry code is used" do
      src =
        (Path.wildcard("lib/**/*.ex") -- ["lib/defk/errors.ex", "lib/defk/test.ex"])
        |> Enum.map_join("\n", &File.read!/1)

      used =
        ~r/"([a-z0-9]+(?:-[a-z0-9]+)+|recursion|pipe)"[,)]/
        |> Regex.scan(src)
        |> MapSet.new(&Enum.at(&1, 1))

      registry = MapSet.new(Defk.Errors.codes(), & &1.code)

      assert MapSet.difference(used, registry) == MapSet.new(), "codes not in the registry"
      assert MapSet.difference(registry, used) == MapSet.new(), "registry codes no module uses"
    end
  end

  describe "format" do
    test "a rejection prints Elixir's frame, why, hint and the code" do
      msg = compile(__MODULE__, "defk f(x :: i64) :: i64 do\n  m = %{a: x}\n  x\nend")
      [_head, block] = String.split(msg, "\n\n", parts: 2)
      file = Regex.run(~r/└─ (\S+):5:9: /, block) |> Enum.at(1)
      mod = Regex.run(~r/: (Defk\.CompileErrorsTest\.\w+)\.f\/1/, block) |> Enum.at(1)

      assert block == """
             error: maps are not in the kernel subset
               │
             5 │    m = %{a: x}
               │        ^^^^^^^
               │
               └─ #{file}:5:9: #{mod}.f/1

             why: a kernel works on numbers, booleans, tuples and packed arrays; a map is a BEAM term it can neither build nor read
             hint: pass the values as separate arguments, or pack them into an array before the call; for a count per key, index an array by the key (counts = alloc(i64, 256), then counts[b] = counts[b] + 1)
             (defk unsupported-map: docs/compile-errors.md#unsupported-map)\
             """

      # the footer links the code's entry in the catalogue page
      assert File.exists?("docs/compile-errors.md")
    end

    test "the link is the page's path inside the defk repository and a URL elsewhere" do
      assert Defk.Errors.docs("pipe") == "docs/compile-errors.md#pipe"
      assert Defk.Errors.docs("pipe", false) =~ ~r{^https://\S+/compile-errors\.(md|html)#pipe$}
      assert Defk.Errors.docs("pipe", false) =~ "compile-errors"
    end

    # an unknown code: the doctest of explain!/1
    test "explain!/1 prints the registry entry" do
      out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!("unsupported-map") end)
      assert out =~ Defk.Errors.fetch!("unsupported-map").summary
      assert out =~ "rewrite:"
    end

    test "the six prototype cases" do
      msg =
        compile(
          __MODULE__,
          """
          defk map(x :: i64) :: i64 do
            m = %{a: x}
            x
          end

          defk string(x :: i64) :: i64 do
            s = "he" <> "llo"
            x
          end

          defk f(x :: i64) :: i64 do
            if x == 0, do: 0, else: f(x - 1)
          end

          defk branch(p :: bool, a :: [f64], b :: [i64]) :: f64 do
            c = if p, do: a, else: b
            c[0]
          end

          defk double(a :: [f64]) :: [f64] do
            b = Enum.map(a, fn x -> x * 2.0 end)
            b
          end

          defk add(x :: i64, y :: f64) :: i64 do
            x + y
          end
          """
        )

      assert msg =~ ~r/^\S+: cannot compile \S+: 6 kernel compile errors\n/

      assert codes(msg) ==
               ~w(unsupported-map unsupported-string recursion branch-types unsupported-call return-type)

      assert whats(msg) == [
               "maps are not in the kernel subset",
               "string concatenation with <> is not in the kernel subset",
               "f/1 calls itself, and recursion is not in the kernel subset",
               "the branches of this if have different types: [f64], [i64]",
               "Enum.map/2 is not in the kernel subset",
               "add/2 returns f64 but is declared :: i64"
             ]

      # carets under the whole construct, as written
      assert msg =~ "5 │    m = %{a: x}\n  │        ^^^^^^^\n"
      assert msg =~ "10 │    s = \"he\" <> \"llo\"\n   │             ^^^^^^^^\n"

      assert msg =~
               "15 │    if x == 0, do: 0, else: f(x - 1)\n   │                            ^^^^^^^^\n"

      assert msg =~ "19 │    c = if p, do: a, else: b\n   │        ^^^^^^^^^^^^^^^^^^^^\n"

      assert msg =~
               "24 │    b = Enum.map(a, fn x -> x * 2.0 end)\n   │        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n"

      assert msg =~ "29 │    x + y\n   │    ^^^^^\n"

      # rewrites from the developer's own code
      assert msg =~ "    for i <- 0..(len(a) - 1)//1 do\n      out[i] = a[i] * 2.0\n    end\n"
      assert msg =~ "    trunc(x + y)    # or declare :: f64\n"
      refute msg =~ ~r/defk-[a-z0-9]{3}/
    end

    test "without a source file the frame is just the location" do
      src = """
      defmodule Defk.CompileErrorsTest.NoFile do
        use Defk
        defk f(x :: i64) :: i64 do
          s = "he" <> "llo"
          x
        end
      end
      """

      msg = Exception.message(assert_raise(CompileError, fn -> Code.compile_string(src) end))

      assert msg =~
               ~r"error: string concatenation with <> is not in the kernel subset\n└─ nofile:4:\d+: Defk.CompileErrorsTest.NoFile.f/1\n\nwhy:"
    end
  end

  describe "collecting rejections" do
    test "every rejection in a module, sorted by line, without cascades" do
      msg =
        compile(
          __MODULE__,
          """
          defk helper(x :: i64) :: i64 do
            x + ("one" <> "two")
          end

          defk f(x :: i64) :: i64 do
            m = %{a: x}
            y = m + 1
            z = helper(x)
            w = undefined_thing(x)
            q = :ok
            y + z + w + x
          end

          defk bad_head(x) :: i64 do
            x
          end

          defk g(x :: i64) :: i64 do
            bad_head(x) + 1
          end
          """
        )

      # helper's string once (not again where f inlines helper); m, y, z and w
      # are poisoned, so their uses report nothing; bad_head's callers are silent
      assert codes(msg) ==
               ~w(unsupported-string unsupported-map unknown-function unsupported-atom untyped-parameter)

      assert msg =~ ": 5 kernel compile errors\n"
    end

    test "the body of a for rejected for its shape is checked too (HexDocs attempt 1)" do
      src = File.read!("docs/cold-tests/hexdocs-entropy/attempt1.ex.txt")
      body = src |> String.split("\n") |> Enum.slice(4..-3//1) |> Enum.join("\n")
      msg = compile(__MODULE__, body)

      # n is poisoned by the byte_size rejection, so the for's range is
      # abandoned and its body is still lowered; the inner reduce's init is
      # rejected and the pipe is one error, nothing in them is looked into
      assert codes(msg) == ~w(unknown-function for-collect unsupported-map pipe)
      assert msg =~ ": 4 kernel compile errors\n"
    end

    test "errors in a rejected for's body are reported once, next to for-collect" do
      msg =
        compile(
          __MODULE__,
          "defk f(a :: [f64], n :: i64) :: [f64] do\n  for i <- 0..(n - 1) do\n    m = %{a: i}\n    m + a[i]\n  end\nend"
        )

      assert codes(msg) == ~w(for-collect unsupported-map)
    end

    test "a for rejected for its shape whose body is valid reports only for-collect" do
      msg =
        compile(
          __MODULE__,
          "defk f(a :: [f64], n :: i64) :: [f64] do\n  for i <- 0..(n - 1) do\n    y = a[i] * 2.0\n    y + 1.0\n  end\nend"
        )

      assert codes(msg) == ["for-collect"]
    end

    test "a for rejected over a poisoned generator source only reports for-collect besides the poisoning error" do
      msg =
        compile(
          __MODULE__,
          "defk f(n :: i64) :: i64 do\n  m = %{a: n}\n  r = for x <- m do\n    x + 1\n  end\n  0\nend"
        )

      assert codes(msg) == ~w(unsupported-map for-collect)
    end

    test "at most 10 are shown" do
      body = Enum.map_join(1..12, "\n", &"  v#{&1} = :a#{&1}")
      msg = compile(__MODULE__, "defk f(x :: i64) :: i64 do\n#{body}\n  x\nend")
      assert msg =~ ": 12 kernel compile errors\n"
      assert Enum.count_until(codes(msg), 11) == 10
      assert msg =~ ~r/\n\n2 more not shown; fix these first$/
    end

    test "mutual recursion is reported once" do
      msg =
        compile(
          __MODULE__,
          """
          defk ping(n :: i64) :: i64 do
            if n > 0, do: pong(n - 1), else: 0
          end

          defk pong(n :: i64) :: i64 do
            ping(n)
          end
          """
        )

      assert codes(msg) == ["recursion"]

      assert whats(msg) == [
               "ping/1 calls itself through pong/1, and recursion is not in the kernel subset"
             ]
    end
  end

  describe "module aliases (defk-kwl)" do
    test "an aliased unsupported module is rejected under its real name" do
      msg =
        compile(
          __MODULE__,
          """
          alias Enum, as: E

          defk f(a :: [i64]) :: i64 do
            E.map(a)
          end
          """
        )

      assert whats(msg) == ["Enum.map/1 is not in the kernel subset"]
    end
  end

  describe "targeted hints for first-write forms" do
    defp rejection(body, sig \\ "a :: [f64], x :: i64, n :: i64", ret \\ "f64") do
      msg = reject(__MODULE__, kernel(sig, ret, body))
      assert [_] = codes(msg), msg
      msg
    end

    test "|> gets the nested call" do
      msg = rejection("a[0] |> abs() |> sqrt()")
      assert whats(msg) == ["the pipe operator |> is not in the kernel subset"]
      assert rewrite(msg) == "sqrt(abs(a[0]))"
    end

    test "Enum.sum over a comprehension gets the reduce loop that compiles" do
      msg = rejection("Enum.sum(for y <- a, y > 0.0, do: y * y)")
      assert whats(msg) == ["Enum.sum/1 is not in the kernel subset"]
      # both zeros are offered; the integer one would change acc's type mid-reduce
      assert rewrite(msg) == "for y <- a, y > 0.0, reduce: 0.0 do\n  acc -> acc + y * y\nend"
    end

    test "Enum.max over an array gets the reduce loop from the first element" do
      msg = rejection("Enum.max(a)")

      assert rewrite(msg) ==
               "for i <- 1..(len(a) - 1)//1, reduce: a[0] do\n  acc -> max(acc, a[i])\nend"
    end

    test "Enum.min over a list literal gets nested min/2" do
      msg = rejection("Enum.min([a[0], a[1], a[2]])")
      assert whats(msg) == ["Enum.min/1 over a list is not in the kernel subset"]
      assert rewrite(msg) == "min(min(a[0], a[1]), a[2])"
    end

    test "Enum.with_index in a generator gets the index generator" do
      msg =
        rejection("for {y, i} <- Enum.with_index(a), reduce: 0.0 do\n  acc -> acc + y * i\nend")

      assert codes(msg) == ["generator-pattern"]
      assert msg =~ "read y = a[i] in the body"
      assert rewrite(msg) == "i <- 0..(len(a) - 1)//1"
    end

    test "for ..., into: gets alloc/2 writes" do
      msg = rejection("for y <- a, into: <<>>, do: <<y::float-64>>", "a :: [f64]", "[f64]")
      assert codes(msg) == ["for-collect"]
      assert whats(msg) == ["for ..., into: is not in the kernel subset"]
    end

    test "a for over 0..(n - 1) used as a value gets alloc, the author's loop and out" do
      msg = rejection("for w <- 0..(n - 1) do\n  w * 2.0\nend", "n :: i64", "[f64]")
      assert codes(msg) == ["for-collect"]

      assert rewrite(msg) ==
               "out = alloc(f64, n)\n\nfor w <- 0..(n - 1)//1 do\n  out[w] = w * 2.0\nend\n\nout"

      assert compile(__MODULE__, kernel("n :: i64", "[f64]", rewrite(msg))) == :ok
    end

    test "a for over a range takes its element type from the body" do
      msg = rejection("for i <- 0..(n - 1)//1, do: a[i] + 1.0", "a :: [f64], n :: i64", "[f64]")
      assert rewrite(msg) =~ "out = alloc(f64, n)"
      msg = rejection("for i <- 0..(n - 1)//1, do: i * 2", "n :: i64", "[i64]")
      assert rewrite(msg) =~ "out = alloc(i64, n)"
    end

    test "a for over another range starts the output at its first element" do
      msg = rejection("for i <- 1..n, do: a[i - 1]", "a :: [f64], n :: i64", "[f64]")

      assert rewrite(msg) ==
               "out = alloc(f64, n)\n\nfor i <- 1..n//1 do\n  out[i - 1] = a[i - 1]\nend\n\nout"

      msg = rejection("for i <- 2..(n + 5), do: i + 0.5", "n :: i64", "[f64]")
      assert rewrite(msg) =~ "out = alloc(f64, n + 5 - 2 + 1)"
      assert rewrite(msg) =~ "out[i - 2] = i + 0.5"
    end

    test "a for over an array gets the index loop, typed by the element" do
      msg = rejection("for x <- a, do: x + 1", "a :: [i64]", "[i64]")
      assert rewrite(msg) =~ "out = alloc(i64, len(a))"
      assert rewrite(msg) =~ "out[i] = a[i] + 1"
    end

    test "a for that is the returned [u8] allocs the declared element type" do
      msg = rejection("for x <- a, do: x", "a :: [u8]", "[u8]")
      assert rewrite(msg) =~ "out = alloc(u8, len(a))"
      assert compile(__MODULE__, kernel("a :: [u8]", "[u8]", rewrite(msg))) == :ok

      # bound to a name that is returned
      msg = rejection("out = for x <- a, do: x\nout", "a :: [u8]", "[u8]")
      assert rewrite(msg) =~ "alloc(u8, len(a))"
    end

    test "a returned for whose body does not fit the declared element keeps its own type" do
      msg = rejection("for x <- a, do: x * 0.5", "a :: [f64]", "[i64]")
      assert rewrite(msg) =~ "out = alloc(f64, len(a))"
      # not the returned value: the body's own type
      msg = rejection("y = for x <- a, do: x\n1", "a :: [u8]", "i64")
      assert rewrite(msg) =~ "out = alloc(i64, len(a))"
    end

    test "a for-collect without a rewrite keeps the generic hint" do
      # a step other than 1, a body of several statements, a nested generator
      for body <- [
            "for i <- 0..(n - 1)//2, do: i",
            "for i <- 0..(n - 1) do\n  y = i * 2\n  y\nend",
            "for i <- 0..(n - 1), j <- 0..(n - 1), do: i + j"
          ] do
        msg = rejection(body, "n :: i64", "[i64]")
        assert codes(msg) == ["for-collect"]
        assert msg =~ "hint: allocate the output array and write it in the loop\n"
        refute msg =~ "alloc(i64"
      end
    end

    test "fixed-field binary matches get indexed reads" do
      msg = rejection("<<b0, b1, _::16, rest::binary>> = a\nb0 + b1", "a :: [u8]", "i64")
      assert codes(msg) == ["bitstring-match"]
      assert rewrite(msg) == "b0 = a[0]\nb1 = a[1]"
    end

    test "reading a float's bits points at f64_to_u64" do
      msg = rejection("<<b::64>> = <<y::float-64>>\nb", "y :: f64", "i64")
      assert codes(msg) == ["bitstring-match"]
      assert msg =~ "b = f64_to_u64(y)"
    end

    test "a literal shift past u64 masks gets the mask hint" do
      msg = rejection("band(x, (1 <<< 65) - 1)", "x :: i64", "i64")
      assert codes(msg) == ["shift-overflow"]
      assert whats(msg) == ["1 <<< 65 does not fit in i64"]
      assert msg =~ "computed at compile time"
    end

    test "byte_size names the builtin, without the by-design wording" do
      msg = rejection("byte_size(a)", "a :: [u8]", "i64")
      assert codes(msg) == ["unknown-function"]
      assert whats(msg) == ["byte_size/1 is not a kernel builtin"]
      assert rewrite(msg) == "len(a)"
    end

    test "a list or String.t type says how the data crosses" do
      msg = compile(__MODULE__, "defk f(xs :: list(f64)) :: f64 do\n  0.0\nend")
      assert codes(msg) == ["unknown-type"]
      assert msg =~ "a list is passed as a packed array"

      msg = compile(__MODULE__, "defk f(d :: [u8]) :: String.t() do\n  d\nend")
      assert codes(msg) == ["unknown-type"]
      assert msg =~ "text is a [u8]"
    end
  end
end
