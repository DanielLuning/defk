defmodule Defk.AllocZeroingTest do
  # The unzeroed-allocation recogniser (Defk.AllocZeroing.mark/1) on bare
  # ASTs: a block's statements in, the alloc marked or not out. No C
  # compiler, no kernel module. alloc_unzeroed_test keeps the end-to-end
  # side: the generated C of each accepted shape and near miss, the report,
  # and agreement after the allocator held 255s.
  use ExUnit.Case, async: true

  alias Defk.AllocZeroing

  # the block's statements, as the compiler sees them
  defp stmts(ast) do
    case ast do
      {:__block__, _, ss} -> ss
      s -> [s]
    end
  end

  # {loop_meta, extents} of the mark on the first alloc, or nil
  defp mark(ast) do
    Enum.find_value(AllocZeroing.mark(stmts(ast)), fn
      {:=, _, [_, {:alloc, m, _}]} -> m[:defk_unzeroed]
      _ -> nil
    end)
  end

  describe "accepted" do
    test "a strided loop writing x[i] over 0..(n - 1)//1; the mark carries the loop's meta" do
      ast =
        quote line: 7 do
          out = alloc(f64, n)

          for i <- 0..(n - 1)//1 do
            out[i] = a[i] * k
          end

          out
        end

      assert {meta, []} = mark(ast)
      assert meta[:line] == 7
    end

    test "k writes per trip, in any order, over 0..(n - 1)" do
      ast =
        quote do
          out = alloc(u8, 2 * n)

          for i <- 0..(n - 1) do
            out[2 * i + 1] = lo(i)
            out[2 * i] = hi(i)
          end
        end

      assert {_, []} = mark(ast)
    end

    test "the range may end at length(x) - 1 for one write per trip" do
      ast =
        quote do
          out = alloc(i64, n)
          for i <- 0..(length(out) - 1)//1, do: out[i] = i * i
        end

      assert {_, []} = mark(ast)
    end

    test "a reduce: loop whose clause body writes every trip" do
      ast =
        quote do
          out = alloc(i64, n)

          acc =
            for i <- 0..(n - 1)//1, reduce: 0 do
              s ->
                out[i] = s
                s + i
            end

          {out, acc}
        end

      assert {_, []} = mark(ast)
    end

    test "unrelated statements may sit between the alloc and the loop" do
      ast =
        quote do
          out = alloc(f64, n)
          scale = 2.0 * k
          for i <- 0..(n - 1)//1, do: out[i] = a[i] * scale
        end

      assert {_, []} = mark(ast)
    end

    test "a nest of range loops writing a row-major index: the extents" do
      ast =
        quote do
          g = alloc(i64, w * h)

          for r <- 0..(h - 1)//1 do
            for c <- 0..(w - 1)//1 do
              g[r * w + c] = r + c
            end
          end
        end

      assert {_, extents} = mark(ast)
      assert Enum.map(extents, &elem(&1, 0)) == [:h, :w]
    end
  end

  describe "near misses keep the zeroing" do
    test "a read of x in the body" do
      ast =
        quote do
          out = alloc(f64, n)
          for i <- 0..(n - 1)//1, do: out[i] = out[i] + 1.0
        end

      assert mark(ast) == nil
    end

    test "a write under a branch" do
      ast =
        quote do
          out = alloc(f64, n)

          for i <- 0..(n - 1)//1 do
            if rem(i, 3) != 0, do: out[i] = 1.0
          end
        end

      assert mark(ast) == nil
    end

    test "a filtered generator" do
      ast =
        quote do
          out = alloc(f64, n)
          for i <- 0..(n - 1)//1, rem(i, 2) == 0, do: out[i] = 1.0
        end

      assert mark(ast) == nil
    end

    test "a range that starts at one or stops early" do
      from_one =
        quote do
          out = alloc(f64, n)
          for i <- 1..(n - 1)//1, do: out[i] = 1.0
        end

      short =
        quote do
          out = alloc(f64, n)
          for i <- 0..(n - 2)//1, do: out[i] = 1.0
        end

      assert mark(from_one) == nil
      assert mark(short) == nil
    end

    test "only some of the k strides are written" do
      ast =
        quote do
          out = alloc(u8, 3 * n)

          for i <- 0..(n - 1)//1 do
            out[3 * i] = 1
            out[3 * i + 2] = 2
          end
        end

      assert mark(ast) == nil
    end

    test "a statement in between rebinds the length, or mentions x" do
      rebinds =
        quote do
          out = alloc(f64, n)
          n = n - 1
          for i <- 0..(n - 1)//1, do: out[i] = 1.0
        end

      mentions =
        quote do
          out = alloc(f64, n)
          m = length(out)
          for i <- 0..(n - 1)//1, do: out[i] = 1.0
        end

      assert mark(rebinds) == nil
      assert mark(mentions) == nil
    end

    test "the body binds the loop variable" do
      ast =
        quote do
          out = alloc(f64, n)

          for i <- 0..(n - 1)//1 do
            i = i + 1
            out[i] = 1.0
          end
        end

      assert mark(ast) == nil
    end

    test "a nest whose extents are not the alloc's, or whose index is not row-major" do
      extent =
        quote do
          g = alloc(i64, w * h)

          for r <- 0..(h - 1)//1 do
            for c <- 0..(w - 2)//1 do
              g[r * w + c] = 1
            end
          end
        end

      index =
        quote do
          g = alloc(i64, w * h)

          for r <- 0..(h - 1)//1 do
            for c <- 0..(w - 1)//1 do
              g[c * h + r] = 1
            end
          end
        end

      assert mark(extent) == nil
      assert mark(index) == nil
    end

    test "an alloc that is not bound to a plain variable, or no loop after it" do
      no_loop =
        quote do
          out = alloc(f64, n)
          out
        end

      assert mark(no_loop) == nil
      assert AllocZeroing.mark([]) == []
    end
  end

  test "every other statement passes through unchanged" do
    ast =
      quote do
        x = a + 1
        out = alloc(f64, n)
        for i <- 0..(n - 1)//1, do: out[i] = x
        out
      end

    [first, _alloc, loop, last] = AllocZeroing.mark(stmts(ast))
    [s1, _, s3, s4] = stmts(ast)
    assert {first, loop, last} == {s1, s3, s4}
  end
end
