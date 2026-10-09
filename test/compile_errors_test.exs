defmodule Defk.CompileErrorsTest do
  # Every error code's example is rejected with that code, and its rewrite
  # compiles (Defk.Errors.codes/0). Also: the format of a compile error, the
  # targeted hints for first-write forms, and collecting every rejection in a
  # module without the errors an earlier one causes.
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "defk_compile_errors_test")

  # the examples and rewrites of every code, compiled concurrently:
  # %{code => {example_result, rewrite_result}}
  setup_all do
    File.mkdir_p!(@dir)

    results =
      Defk.Errors.codes()
      |> Enum.filter(& &1.example)
      |> Task.async_stream(
        fn e -> {e.code, {compile(e.example, "Ex"), compile(e.rewrite, "Rw")}} end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{results: results}
  end

  # Compile `body` (kernels) in a fresh module from a file, so errors have
  # source lines. Returns :ok or the CompileError message.
  defp compile(body, tag) do
    mod = "Defk.CompileErrorsTest.M#{tag}#{System.unique_integer([:positive])}"
    path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")

    indented =
      body |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: "  " <> &1))

    File.write!(path, "defmodule #{mod} do\n  use Defk\n\n#{indented}\nend\n")

    try do
      Code.compile_file(path)
      :ok
    rescue
      e in CompileError -> Exception.message(e)
    end
  end

  defp codes(msg),
    do:
      Regex.scan(~r/^\(defk ([a-z0-9-]+)[:;] /m, msg)
      |> Enum.map(&Enum.at(&1, 1))

  defp whats(msg), do: Regex.scan(~r/^error: (.*)$/m, msg) |> Enum.map(&Enum.at(&1, 1))

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

    test "codes are unique slugs with a summary, why and hint" do
      codes = Enum.map(Defk.Errors.codes(), & &1.code)
      assert codes == Enum.uniq(codes)

      for e <- Defk.Errors.codes() do
        assert e.code =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
        assert e.kind in [:subset, :planned, :error]

        for k <- [:summary, :why, :hint],
            do: assert(is_binary(Map.fetch!(e, k)) and e[k] != "", "#{e.code} #{k}")
      end
    end

    test "every code the compiler uses is in the registry, and every registry code is used" do
      src = File.read!("lib/defk/compiler.ex") <> File.read!("lib/defk/errors.ex")

      used =
        Regex.scan(~r/\{?"([a-z0-9]+(?:-[a-z0-9]+)+|recursion|pipe)",/, src)
        |> Enum.map(&Enum.at(&1, 1))

      registry = MapSet.new(Defk.Errors.codes(), & &1.code)

      assert MapSet.subset?(MapSet.new(used), registry),
             inspect(MapSet.difference(MapSet.new(used), registry))

      assert MapSet.subset?(registry, MapSet.new(used)),
             inspect(MapSet.difference(registry, MapSet.new(used)))
    end
  end

  describe "format" do
    test "a rejection prints Elixir's frame, why, hint and the code" do
      msg = compile("defk f(x :: i64) :: i64 do\n  m = %{a: x}\n  x\nend", "Fmt")
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
             hint: pass the values as separate arguments, or pack them into an array before the call
             (defk unsupported-map: docs/language.md#unsupported-map)\
             """
    end

    test "the footer names the code's anchor in docs/language.md" do
      assert File.exists?("docs/language.md")
      msg = compile("defk f(x :: i64) :: i64 do\n  m = %{a: x}\n  x\nend", "Footer")
      assert msg =~ "(defk unsupported-map: docs/language.md#unsupported-map)"
      refute msg =~ "explain!"
    end

    test "explain!/1 prints the registry entry and rejects unknown codes" do
      out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!("unsupported-map") end)
      assert out =~ Defk.Errors.fetch!("unsupported-map").summary
      assert out =~ "rewrite:"

      assert_raise ArgumentError, ~r/unknown defk error code/, fn ->
        Defk.Errors.explain!("no-such-code")
      end
    end

    test "the six prototype cases" do
      msg =
        compile(
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

          defk branch(p :: bool, a :: [f64], b :: [f64]) :: f64 do
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
          """,
          "Six"
        )

      assert msg =~ ~r/^\S+: cannot compile \S+: 6 kernel compile errors\n/

      assert codes(msg) ==
               ~w(unsupported-map unsupported-string recursion array-in-branch unsupported-call return-type)

      assert whats(msg) == [
               "maps are not in the kernel subset",
               "string concatenation with <> is not in the kernel subset",
               "f/1 calls itself, and recursion is not in the kernel subset",
               "this if gives an array ([f64]); arrays from an if are not supported yet",
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
      assert msg =~
               "hint: do the array work inside each branch:\n\n    if p, do: a[0], else: b[0]\n"

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
          """,
          "Many"
        )

      # helper's string once (not again where f inlines helper); m, y, z and w
      # are poisoned, so their uses report nothing; bad_head's callers are silent
      assert codes(msg) ==
               ~w(unsupported-string unsupported-map unknown-function unsupported-atom untyped-parameter)

      assert msg =~ ": 5 kernel compile errors\n"
    end

    test "at most 10 are shown" do
      body = Enum.map_join(1..12, "\n", &"  v#{&1} = :a#{&1}")
      msg = compile("defk f(x :: i64) :: i64 do\n#{body}\n  x\nend", "Cap")
      assert msg =~ ": 12 kernel compile errors\n"
      assert Enum.count_until(codes(msg), 11) == 10
      assert msg =~ ~r/\n\n2 more not shown; fix these first$/
    end

    test "mutual recursion is reported once" do
      msg =
        compile(
          """
          defk ping(n :: i64) :: i64 do
            if n > 0, do: pong(n - 1), else: 0
          end

          defk pong(n :: i64) :: i64 do
            ping(n)
          end
          """,
          "Rec"
        )

      assert codes(msg) == ["recursion"]

      assert whats(msg) == [
               "ping/1 calls itself through pong/1, and recursion is not in the kernel subset"
             ]
    end
  end

  describe "targeted hints for first-write forms" do
    defp rejection(body, sig \\ "a :: [f64], x :: i64, n :: i64", ret \\ "f64") do
      msg =
        compile(
          "defk f(#{sig}) :: #{ret} do\n#{body |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))}\nend",
          "Hint"
        )

      assert [_] = codes(msg), msg
      msg
    end

    defp rewrite(msg) do
      [_, rw] = Regex.run(~r/^hint: .*:\n\n((?:    .*\n|\n)+)\(defk/m, msg)

      rw
      |> String.split("\n")
      |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
      |> String.trim_trailing()
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

    test "fixed-field binary matches get indexed reads" do
      msg = rejection("<<b0, b1, _::16, rest::binary>> = a\nb0 + b1", "a :: [u8]", "i64")
      assert codes(msg) == ["bitstring-match"]
      assert rewrite(msg) == "b0 = a[0]\nb1 = a[1]"
    end

    test "reading a float's bits names the planned builtin" do
      msg = rejection("<<b::64>> = <<y::float-64>>\nb", "y :: f64", "i64")
      assert codes(msg) == ["bitstring-match"]
      assert msg =~ "Defk.Bits.f64_to_u64/1, is planned"
    end

    test "a literal mask (1 <<< 64) - 1 that overflows i64 gets the mask hint" do
      msg = rejection("band(x, (1 <<< 64) - 1)", "x :: i64", "i64")
      assert codes(msg) == ["shift-overflow"]
      assert whats(msg) == ["1 <<< 64 does not fit in i64"]
      assert msg =~ "0x7FFFFFFFFFFFFFFF"
    end
  end
end
