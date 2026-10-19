defmodule Defk.Strip do
  # The strip record and the flagged-strip classifier.
  #
  # The record is what the lowering declares, as it emits, about the
  # statements that may end up inside a flat loop's strip: whole-variable
  # assignments with their right-hand side's C (so a float read, a float
  # tree or a scalar copy is recognisable from its row), addresses taken,
  # element writes, raw element accesses with their bounds proof's support
  # (Defk.Facts.prove_in_bounds), and float trees with their sticky leaves.
  # Each row carries its position (seq), the branch arms it sits under
  # (path, outermost last) and whether it sits in a conditional expression
  # (cond). The record is pure: state in, state out. The compiler keeps the
  # state at `ctx.lowering.strip`, so with_acc_facts' backtracking snapshot
  # covers it, and owns the storage shim (`srec_*` in Defk.Compiler).
  #
  # The classifier (classify/5) decides from the rows whether a flat loop
  # body can run flagged, and if so how, instead of re-parsing the C text
  # it was handed. Each decision mirrors the text analysis it replaced
  # exactly (bug-for-bug: the gate demanded byte-identical C), except where
  # a mirrored bug was fixed since (reaches?/3). Token-presence scans over
  # the body text stay (@nf_call, ctx-in-rest, the [vp]_ variable roster):
  # they reconstruct no structure and fail safe. What moved to rows is
  # everything that used to re-derive structure from the text: writes,
  # element writes, index composition with proof support, float reads and
  # trees with their sticky leaves, scalar copies, and branch positions.
  @moduledoc false

  defstruct seq: 0, path: [], cond: false, rows: []

  @type t :: %__MODULE__{seq: non_neg_integer, path: list, cond: boolean, rows: [map]}

  def new, do: %__MODULE__{}

  # ------------------------------------------------------------ the record --

  defp row(%__MODULE__{seq: seq, path: path, cond: cond?, rows: rows} = st, row) do
    row = Map.merge(row, %{seq: seq, path: path, cond: cond?})
    %{st | seq: seq + 1, rows: [row | rows]}
  end

  def assign(st, var, rhs), do: row(st, %{k: :assign, var: var, rhs: IO.iodata_to_binary([rhs])})

  def addr(st, var), do: row(st, %{k: :addr, var: var})

  # an element write; `checked?` is whether the store checks its bounds
  def elem_write(st, arr, checked?), do: row(st, %{k: :elem_write, arr: arr, checked: checked?})

  # a raw (proof-dropped) element access, read or write; kind :index for
  # (a).data[i], :load for a word load's (a).data + i
  def access(st, kind, arr, idx, support),
    do: row(st, %{k: :access, access: kind, arr: arr, idx: idx, support: support})

  def ftree(st, f, anchor, leaves),
    do: row(st, %{k: :ftree, f: f, anchor: anchor, leaves: leaves})

  # the rows recorded since `first` (oldest first); paths are relative to
  # `entry`, the path where recording started (the strip body's own arms)
  def rows_since(%__MODULE__{rows: rows}, first, entry) do
    base = length(entry)

    rows =
      for r <- rows, r.seq >= first do
        %{r | path: Enum.take(r.path, length(r.path) - base)}
      end

    Enum.reverse(rows)
  end

  # rows recorded from here on run only when arm `arm` of the branch `ref`
  # does; leave_arm/2 restores the path saved before enter_arm/3
  def enter_arm(%__MODULE__{} = st, ref, arm), do: %{st | path: [{ref, arm} | st.path]}

  def leave_arm(%__MODULE__{} = st, path), do: %{st | path: path}

  # drop branch frame `ref` from every row: a short-circuit right side that
  # turned out inline runs with its statement after all
  def drop_frame(%__MODULE__{rows: rows} = st, ref) do
    rows =
      Enum.map(rows, fn row ->
        %{row | path: Enum.reject(row.path, &match?({^ref, _}, &1))}
      end)

    %{st | rows: rows}
  end

  # -------------------------------------------------------- the classifier --

  # write ranges and float-to-integer conversions.
  @nf_helpers ~w(fadd fsub fmul fdiv in_f64 sqrt log log2 log10 exp pow to_f32)
  @nf_joins ~w(add_i64 sub_i64 mul_i64 neg_i64 abs_i64 add_u64 sub_u64 mul_u64 trunc round
               get_in_f64 to_u8 to_i16 to_i32) ++
              for(t <- ~w(f64 i64 u8 u64 i16 i32 f32), op <- ~w(get put), do: "#{op}_#{t}")
  @nf_all @nf_helpers ++ @nf_joins
  @nf_call ~r/\bdefk_(?:#{Enum.join(@nf_helpers, "|")})\(ctx,/
  @nf_join_call ~r/\bdefk_(?:#{Enum.join(@nf_joins, "|")})\(ctx,/
  # a float_tree check's replay: no braces inside (its operands are pure)
  @nf_replay ~r/DEFK_FCHECK\([^{}]*\) \{[^{}]*\}/
  @nf_scalars ~w(int64_t double int uint64_t)

  # Whether a flat loop body can run flagged, and if so how: the snapshot
  # (decls, snap, restore), the flagged body and the extra end-of-strip test
  # (sticky/1). `text` is the body's C, `var` the loop counter, `rows` the
  # record of the body, `types` the kernel's C declarations ({name, type}).
  # It can when:
  #   * it has a float check: a strip without one gains nothing;
  #   * the only use of ctx (every error goes through it) is in a check that
  #     becomes a flag: a float check, or one that joins it (@nf_joins: i64
  #     overflow, an element access). Any other error (a
  #     CaseClauseError, a division by zero) could be raised before an earlier
  #     flagged one;
  #   * with a joined check, every unchecked a.data[i] has an index made only
  #     of the loop counter and values not assigned in the strip
  #     (fixed_indices?/3), so a wrong value from a failed check, which the
  #     flagged run computes on with, never reaches an address;
  #   * every local it mentions is a scalar, so a snapshot of those restores
  #     the strip's start state (unchanged ones fold away), or an array (in
  #     the snapshot when it is assigned whole, as array accumulators are);
  #   * an array it writes is not otherwise mentioned (no read of it, so the
  #     replay recomputes the values it wrote) and no input array is written.
  def classify(id, text, var, rows, types) do
    rest = unflagged_rest(text)
    joined = Regex.match?(@nf_join_call, text)
    types = Map.new(types)

    vars =
      Regex.scan(~r/\b[vp]_\w+/, text)
      |> List.flatten()
      |> Enum.uniq()

    {arrays, others} =
      Enum.split_with(vars, &String.starts_with?(types[&1] || "", "defk_arr_"))

    {params, locals} = Enum.split_with(others, &String.starts_with?(&1, "p_"))

    with true <- Regex.match?(@nf_call, text) or String.contains?(text, "DEFK_FCHECK("),
         false <- Regex.match?(~r/\bctx\b/, rest),
         true <- not joined or fixed_indices?(rows, var),
         true <- Enum.all?(locals, &(types[&1] in @nf_scalars)),
         false <- Enum.any?(params, &(written?(rows, &1) or array_writes(rows, &1) > 0)),
         true <- replayable?(text, rows, arrays) do
      saved = locals ++ Enum.filter(arrays, &written?(rows, &1))
      named = Enum.with_index(saved, fn v, n -> {v, "defk_s#{id}_#{n}", types[v]} end)
      sticky = sticky(rows)

      flagged =
        Enum.reduce(sticky, text, fn {_, f}, t ->
          String.replace(t, "DEFK_FCHECK(DEFK_NONFIN(#{f}))", "if (0)")
        end)
        |> seen_later(rows)

      %{
        decls: Enum.map(named, fn {_, s2, t} -> "#{t} #{s2};\n" end),
        snap: Enum.map(named, fn {v, s2, _} -> "#{s2} = #{v};\n" end),
        restore: Enum.map(named, fn {v, s2, _} -> "#{v} = #{s2};\n" end),
        body: flagged,
        test: Enum.map(sticky, fn {x, _} -> " | DEFK_NONFIN(#{x})" end),
        joined: joined,
        helpers: Enum.filter(@nf_all, &String.contains?(flagged, "defk_#{&1}(ctx,"))
      }
    else
      _ -> nil
    end
  end

  # For a flat loop that is not flagged: why its float checks stay, or nil
  # when the body has no float check (nothing to explain).
  def unflagged_reason(text, var, rows) do
    if Regex.match?(@nf_call, text) do
      cond do
        Regex.match?(~r/\bctx\b/, unflagged_rest(text)) ->
          "the body can also raise otherwise (a division, a no-match, a check that cannot set a flag)"

        not fixed_indices?(rows, var) ->
          "an unchecked element access uses an index assigned in the loop body from a value a flagged strip could compute wrongly after a failed check"

        true ->
          "the body's state cannot be restored from a snapshot to replay a strip"
      end
    end
  end

  defp writes(rows, v), do: Enum.count(rows, &(&1.k in [:assign, :addr] and &1.var == v))

  defp written?(rows, v), do: writes(rows, v) > 0

  defp array_writes(rows, a), do: Enum.count(rows, &(&1.k == :elem_write and &1.arr == a))

  # an i64 + - * of such values in an index computes the checked value: the
  # bounds proof bounds the result, so it cannot overflow
  @index_words ~w(INT64_C UINT64_C int64_t uint64_t len ctx defk_add_i64 defk_sub_i64 defk_mul_i64)

  # the words a strip-assigned value may be computed from and stay exact in
  # a flagged run: no checked helper (one that flags computes a wrapped value
  # after a failure), so only the arithmetic the compiler proved cannot fail
  @fixed_words ~w(INT64_C UINT64_C int64_t uint64_t len)

  # The proof that dropped an index's check may reason about atoms its text
  # does not name (a bound of the counter, an exact form of a binding):
  # its support has to be fixed too, or a value the run computed wrongly
  # could stand behind it (ADR-0007).
  defp fixed_indices?(rows, var) do
    Enum.all?(rows, fn
      %{k: :access, access: :index, idx: idx, support: support} ->
        fixed_index?(idx, rows, var) and
          Enum.all?(support, &(&1 == var or fixed_var?(&1, rows, var, [])))

      %{k: :access} ->
        false

      _ ->
        true
    end)
  end

  # An index is fixed when every value in it is one the flagged run computes
  # exactly: the loop counter, a value not assigned in the strip, or one the
  # strip assigns once, unconditionally and at the top level, from fixed
  # values alone with no checked helper (fixed_var?/4). A value read from
  # memory, a division, a conversion or a float fails the word test.
  defp fixed_index?(idx, rows, var) do
    Regex.scan(~r/[A-Za-z_]\w*/, idx)
    |> List.flatten()
    |> Enum.all?(fn w ->
      w in @index_words or w == var or
        (Regex.match?(~r/^[vp]_\w+$/, w) and fixed_var?(w, rows, var, []))
    end)
  end

  # `seen`: the values whose assignments are being followed (a cycle)
  defp fixed_var?(w, rows, var, seen) do
    case Enum.filter(rows, &(&1.k in [:assign, :addr] and &1.var == w)) do
      [] ->
        true

      # one plain assignment from fixed words (a value assigned from itself,
      # or through a cycle, is not fixed)
      [%{k: :assign, rhs: rhs, path: [], cond: false}] ->
        w not in seen and
          Regex.scan(~r/[A-Za-z_]\w*/, rhs)
          |> List.flatten()
          |> Enum.all?(fn x ->
            x in @fixed_words or x == var or
              (Regex.match?(~r/^[vp]_\w+$/, x) and fixed_var?(x, rows, var, [w | seen]))
          end)

      _ ->
        false
    end
  end

  defp replayable?(text, rows, arrays) do
    counts = Enum.map(arrays, fn a -> {length(mentions(text, a)), array_writes(rows, a)} end)
    Enum.all?(counts, fn {_, w} -> w == 0 end) or Enum.all?(counts, fn {m, w} -> m == w end)
  end

  defp fread(rhs) do
    cond do
      String.starts_with?(rhs, "defk_in_f64(ctx, ") -> "defk_in_f64"
      String.starts_with?(rhs, "defk_get_in_f64(ctx, ") -> "defk_get_in_f64"
      true -> nil
    end
  end

  defp ftree_f(rhs) do
    case Regex.run(~r/^\(\{ double (f_\d+) = /, rhs) do
      [_, f] -> f
      _ -> nil
    end
  end

  defp sticky(rows) do
    leaves = Map.new(for %{k: :ftree, f: f, leaves: ls} <- rows, ls != nil, do: {f, ls})

    tops =
      for %{k: :assign, var: x, rhs: rhs, path: [], cond: false} <- rows,
          f = ftree_f(rhs),
          do: {x, f}

    copies =
      for %{k: :assign, var: d, rhs: r, path: [], cond: false} <- rows,
          Regex.match?(~r/^v_\w+$/, r),
          do: [d, r]

    once? = fn v -> writes(rows, v) == 1 end

    for {x, f} <- tops,
        ls = leaves[f],
        ls != nil,
        sticky_path?(x, ls, copies, once?, []),
        do: {x, f}
  end

  defp seen_later(text, rows) do
    freads = for %{k: :assign, var: y, rhs: rhs} = r <- rows, h = fread(rhs), do: {r, y, h}
    trees = for %{k: :assign, var: y, rhs: rhs} = r <- rows, f = ftree_f(rhs), do: {r, y, f}

    text =
      Enum.reduce(freads, text, fn {r, y, h}, t ->
        if reaches?(rows, y, r) do
          later = if h == "defk_in_f64", do: "defk_in_f64_later", else: "defk_get_f64"
          String.replace(t, "#{y} = #{h}(ctx, ", "#{y} = #{later}(ctx, ")
        else
          t
        end
      end)

    Enum.reduce(trees, text, fn {r, y, f}, t ->
      if reaches?(rows, y, r),
        do: String.replace(t, "DEFK_FCHECK(DEFK_NONFIN(#{f}))", "if (0)"),
        else: t
    end)
  end

  # Whether `y`, assigned by row `from`, reaches a checked use later in the
  # strip. A tree whose own variable is one of its leaves (acc = acc + ...)
  # is not a later use of itself: the old text scan counted it (and the
  # first strip record mirrored that), which removed the check of an
  # accumulator updated under a branch (a filter's) with no end-of-strip
  # test behind it, so an inf never raised. The unconditional accumulator still drops its
  # check: it is sticky (sticky/1), and the end-of-strip test covers it.
  defp reaches?(rows, y, from) do
    uses =
      for %{k: :ftree, leaves: ls, seq: t} = u <- rows,
          ls != nil,
          y in ls,
          t > from.seq,
          do: u

    copies = for %{k: :assign, rhs: rhs, seq: t} = c <- rows, t > from.seq, rhs == y, do: c

    reached? = fn to ->
      runs_after?(from, to) and unchanged?(rows, y, from, to)
    end

    Enum.any?(uses, reached?) or
      Enum.any?(copies, fn c ->
        runs_after?(from, c) and unchanged?(rows, y, from, c) and
          reaches?(rows, c.var, c)
      end)
  end

  defp suffix?(inner, outer), do: inner == Enum.drop(outer, length(outer) - length(inner))

  defp runs_after?(from, to) do
    to.seq > from.seq and length(to.path) <= length(from.path) and
      suffix?(to.path, from.path) and to.cond == false
  end

  defp unchanged?(rows, y, from, to) do
    writes =
      for %{k: k, var: v, seq: w} = r <- rows,
          k in [:assign, :addr],
          v == y,
          w > from.seq,
          w < to.seq,
          do: r

    case from.path do
      [{ref, arm} | _] ->
        Enum.all?(writes, fn w ->
          Enum.any?(w.path, fn {r2, a2} -> r2 == ref and a2 != arm end)
        end)

      [] ->
        writes == []
    end
  end

  # the body without the checks a flagged strip turns into flags: any ctx
  # left is a check that must raise where it fails
  defp unflagged_rest(text) do
    text
    |> String.replace(@nf_replay, "")
    |> String.replace(@nf_call, "")
    |> String.replace(@nf_join_call, "")
  end

  defp sticky_path?(v, leaves, copies, once?, seen) do
    once?.(v) and v not in seen and
      (v in leaves or
         case for [dst, ^v] <- copies, do: dst do
           [next] -> sticky_path?(next, leaves, copies, once?, [v | seen])
           _ -> false
         end)
  end

  defp mentions(text, a) do
    Regex.scan(~r/\b#{Regex.escape(a)}\b/, text, return: :index)
    |> Enum.map(fn [{at, _}] -> at end)
  end
end
