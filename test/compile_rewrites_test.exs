defmodule Defk.CompileRewritesTest do
  # Every rewrite the compiler writes from the developer's code compiles where
  # the rejected construct was, or the error has no rewrite (only the hint).
  # Each case is a kernel body with `@@` where the construct goes: the body
  # with the construct is rejected, and the body with the rewrite in its place
  # compiles. Also: a compiler crash is never hidden behind a rejection.
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "defk_compile_rewrites_test")

  # {construct, params, return type, body template, :rewrite | :none}
  @cases [
    # |>, in, **, unless, length/1
    {"a[0] |> abs() |> sqrt()", "a :: [f64]", "f64", "@@", :rewrite},
    {"a |> Enum.sum()", "a :: [f64]", "f64", "@@", :none},
    {"x in [1, 2, 3]", "x :: i64", "bool", "@@", :rewrite},
    {"x ** 3", "x :: i64", "i64", "@@", :rewrite},
    {"x ** 0", "x :: i64", "i64", "@@", :rewrite},
    {"(x + 1) ** 2", "x :: i64", "i64", "@@", :rewrite},
    {"y ** 2", "y :: f64", "f64", "@@", :rewrite},
    {"x ** y", "x :: i64, y :: f64", "f64", "@@", :rewrite},
    {"x ** n", "x :: i64, n :: i64", "i64", "@@", :none},
    {"unless x > 0, do: 0, else: x", "x :: i64", "i64", "@@", :rewrite},
    {"length(a)", "a :: [f64]", "i64", "@@", :rewrite},
    {"byte_size(b)", "b :: [u8]", "i64", "@@", :rewrite},
    # Enum.map/2 and collecting for
    {"Enum.map(a, fn x -> x * 2.0 end)", "a :: [f64]", "[f64]", "@@", :rewrite},
    {"Enum.map(a, fn x -> x + 1 end)", "a :: [i64]", "[i64]", "@@", :rewrite},
    {"Enum.map(a, fn x -> x + out end)", "a :: [i64], out :: i64", "[i64]", "@@", :rewrite},
    {"Enum.map(0..(n - 1)//1, fn i -> i * 2 end)", "n :: i64", "[i64]", "@@", :rewrite},
    {"for w <- 0..(n - 1), do: w * 2.0", "n :: i64", "[f64]", "@@", :rewrite},
    {"for i <- 1..n//1, do: a[i - 1] + 1.0", "a :: [f64], n :: i64", "[f64]", "@@", :rewrite},
    {"for i <- 0..(n - 1)//2, do: i", "n :: i64", "[i64]", "@@", :none},
    {"for y <- a, do: y * 2.0", "a :: [f64]", "[f64]", "@@", :rewrite},
    {"for y <- a, into: <<>>, do: <<y::float-native-64>>", "a :: [f64]", "[f64]", "@@", :rewrite},
    {"for y <- a, into: <<>>, do: <<y::native-64>>", "a :: [i64]", "[i64]", "@@", :rewrite},
    {"for c <- b, into: <<>>, do: <<c>>", "b :: [u8]", "[u8]", "@@", :rewrite},
    {"for y <- a, into: <<>>, do: <<y::float-64>>", "a :: [f64]", "[f64]", "@@", :none},
    # Enum.sum/1 and Enum.product/1
    {"Enum.sum(a)", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.sum(xs)", "xs :: [i64]", "i64", "@@", :rewrite},
    {"Enum.sum(for y <- a, y > 0.0, do: y * y)", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.product(1..n//1)", "n :: i64", "i64", "@@", :rewrite},
    # Enum.min/max/min_by/max_by/min_max
    {"Enum.min([a[0], a[1], a[2]])", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.max(a)", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.min(xs)", "xs :: [i64], i :: i64", "i64", "@@ + i", :rewrite},
    {"Enum.max(for y <- a, do: y * y)", "a :: [f64]", "f64", "@@", :none},
    {"Enum.min_by(a, fn x -> abs(x - 1.0) end)", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.max_by(xs, fn x -> rem(x, best) end)", "xs :: [i64], best :: i64", "i64", "@@",
     :rewrite},
    {"Enum.max_by(xs, fn x -> rem(x, 7) end)", "xs :: [i64]", "i64", "@@", :rewrite},
    {"Enum.min_max(a)", "a :: [f64]", "f64", "{lo, hi} = @@\nhi - lo", :rewrite},
    # other Enum functions
    {"Enum.with_index(a)", "a :: [f64]", "f64", "@@", :none},
    {"Enum.reduce(a, 0.0, fn x, acc -> acc + x end)", "a :: [f64]", "f64", "@@", :rewrite},
    {"Enum.reduce(a, 0.0, &+/2)", "a :: [f64]", "f64", "@@", :none},
    {"Enum.find_index(a, fn x -> x > t end)", "a :: [f64], t :: f64", "i64", "@@", :rewrite},
    {"Enum.find_index(a, fn x -> x > i end)", "a :: [f64], i :: f64", "i64", "@@", :rewrite},
    {"Enum.find(a, fn x -> x > t end)", "a :: [f64], t :: f64", "f64", "@@", :none},
    {"Enum.count(a, fn x -> x > 0.0 end)", "a :: [f64]", "i64", "@@", :rewrite},
    {"Enum.each(a, fn x -> x end)", "a :: [f64]", "f64", "@@\n0.0", :rewrite}
  ]

  setup_all do
    File.mkdir_p!(@dir)

    results =
      @cases
      |> Task.async_stream(
        fn {construct, params, ret, template, _} = c ->
          msg = compile({c, :construct}, params, ret, String.replace(template, "@@", construct))
          rw = if is_binary(msg), do: rewrite(msg)

          fixed =
            if rw, do: compile({c, :rewrite}, params, ret, String.replace(template, "@@", rw))

          {c, {msg, rw, fixed}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{results: results}
  end

  # The name comes from the case, not a counter: the same name and source on
  # the next run hit the build cache, where a new library costs a C compile
  # and a first dlopen. `key` is unique per compile, so no two tasks define
  # one module at the same time.
  defp compile(key, params, ret, body) do
    id = :erlang.md5(:erlang.term_to_binary({key, body})) |> Base.encode16() |> binary_part(0, 12)
    mod = "Defk.CompileRewritesTest.M#{id}"
    path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")

    body =
      body |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: "    " <> &1))

    File.write!(
      path,
      "defmodule #{mod} do\n  use Defk\n\n  defk f(#{params}) :: #{ret} do\n#{body}\n  end\nend\n"
    )

    try do
      Code.compile_file(path)
      :ok
    rescue
      e in CompileError -> Exception.message(e)
    end
  end

  # the rewrite under the hint, unindented; nil without one
  defp rewrite(msg) do
    case Regex.run(~r/^hint: .*:\n\n((?:    .*\n|\n)+)\(defk/m, msg) do
      [_, rw] ->
        rw
        |> String.split("\n")
        |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
        |> String.trim_trailing()

      nil ->
        nil
    end
  end

  describe "generated rewrites" do
    for {construct, params, _ret, template, expect} = c <- @cases do
      @case c
      test "#{construct} in #{template} (#{params}): #{expect}", %{results: results} do
        {msg, rw, fixed} = Map.fetch!(results, @case)
        # in a `case` on elem(@case, 4) the compiler narrows the expectation
        # to one literal per generated test and warns about the other clause
        check(elem(@case, 4), msg, rw, fixed)
      end
    end
  end

  defp check(:rewrite, msg, rw, fixed) do
    assert is_binary(msg)
    assert [_] = Regex.scan(~r/^\(defk [a-z0-9-]+[:;] /m, msg), msg
    assert rw, "no rewrite in:\n#{msg}"
    assert fixed == :ok, "the rewrite does not compile:\n#{rw}\n\n#{fixed}"
  end

  defp check(:none, msg, rw, _fixed) do
    assert is_binary(msg)
    assert [_] = Regex.scan(~r/^\(defk [a-z0-9-]+[:;] /m, msg), msg
    assert rw == nil, "unexpected rewrite:\n#{rw}"
  end

  describe "internal compiler crashes" do
    # A kernel whose body crashes the compiler (an improper argument list is
    # not valid Elixir AST, so no source can produce it), after a kernel that
    # is rejected: the crash surfaces, it is not taken as a consequence of the
    # rejection.
    defp kernel(head, body), do: %{head: head, opts: [], body: body, line: 1}

    test "a crash lowering a later kernel surfaces after a rejection" do
      kernels = [
        kernel(quote(do: f(x :: i64) :: i64), quote(do: %{a: x})),
        kernel(quote(do: g(x :: i64) :: i64), {:g2, [line: 1], [1 | 2]})
      ]

      e = catch_error(Defk.Compiler.compile(Defk.CompileRewritesTest.Crash, kernels, nil))
      refute match?(%CompileError{}, e), "the crash was reported as a rejection: #{inspect(e)}"
    end

    test "a crash parsing a later kernel surfaces after a rejection" do
      kernels = [
        kernel(quote(do: f(x) :: i64), quote(do: x)),
        %{kernel(quote(do: g(x :: i64) :: i64), quote(do: x)) | opts: :not_a_keyword_list}
      ]

      e = catch_error(Defk.Compiler.compile(Defk.CompileRewritesTest.Crash, kernels, nil))
      refute match?(%CompileError{}, e), "the crash was reported as a rejection: #{inspect(e)}"
    end

    test "the rejection alone is a CompileError" do
      kernels = [kernel(quote(do: f(x :: i64) :: i64), quote(do: %{a: x}))]

      assert_raise CompileError, fn ->
        Defk.Compiler.compile(Defk.CompileRewritesTest.Crash, kernels, nil)
      end
    end
  end
end
