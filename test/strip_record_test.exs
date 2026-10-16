# The flagged-strip classifier decides from the strip record: rows the
# lowering declared while emitting a flat loop's body. These
# tests state each eligibility rule and rewrite decision on constructed
# rows and a minimal body text — what used to be observable only by
# compiling a kernel and grepping its C. The strip/yield end-to-end tests
# keep covering the runtime contract (replay order, resumes, agreement).
defmodule Defk.StripRecordTest do
  use ExUnit.Case, async: false

  # the classifier reads the kernel's C declarations for variable types,
  # from the compiler's one ctx key
  defp with_types(types) do
    lowering = %Defk.Compiler.Ctx.Lowering{decls: types}
    Process.put(:defk_ctx, %Defk.Compiler.Ctx{lowering: lowering})
  end

  defp rows(specs) do
    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, seq} ->
      Map.merge(%{seq: seq, path: [], cond: false}, spec)
    end)
  end

  defp classify(text, rs, var \\ "v_i_0") do
    Defk.Compiler.__flag_strip_rows__(7, text, var, rs)
  end

  @read "defk_in_f64(ctx, (p_a).data[v_i_0], v_i_0)"
  @tree "({ double f_1 = (v_acc_2 + v_y_1); DEFK_FCHECK(DEFK_NONFIN(f_1)) { double f_0 = defk_fadd(ctx, v_acc_2, v_y_1);\n(void)f_0; defk_nonfinite_lost(ctx); } f_1; })"

  defp base_text do
    "v_y_1 = #{@read};\n" <>
      "v_acc_2 = #{@tree};\n" <>
      "v_i_0 += 1;\n"
  end

  defp base_rows do
    rows([
      %{k: :access, access: :index, arr: "p_a", idx: "v_i_0", support: ["p_a"]},
      %{k: :assign, var: "v_y_1", rhs: @read},
      %{
        k: :ftree,
        f: "f_1",
        anchor: "DEFK_FCHECK(DEFK_NONFIN(f_1))",
        leaves: ["v_acc_2", "v_y_1"]
      },
      %{k: :assign, var: "v_acc_2", rhs: @tree},
      %{k: :assign, var: "v_i_0", rhs: "v_i_0 + step"}
    ])
  end

  defp base_types,
    do: [
      {"v_y_1", "double"},
      {"v_acc_2", "double"},
      {"v_i_0", "int64_t"},
      {"p_a", "defk_arr_f64"}
    ]

  test "a sticky accumulator: its check waits for the strip's end" do
    with_types(base_types())
    fl = classify(base_text(), base_rows())

    assert fl.test == [" | DEFK_NONFIN(v_acc_2)"]
    assert IO.iodata_to_binary(fl.body) =~ "if (0)"
    refute IO.iodata_to_binary(fl.body) =~ "DEFK_FCHECK"
  end

  describe "an accumulator that is a leaf of its own tree" do
    # the base strip's tree and its assignment under a branch arm (a
    # filter's), plus whatever `extra` rows and text follow them
    defp arm_rows(extra) do
      ref = make_ref()

      base_rows()
      |> Enum.map(fn
        %{k: :ftree} = r -> %{r | path: [{ref, 0}]}
        %{k: :assign, var: "v_acc_2"} = r -> %{r | path: [{ref, 0}]}
        r -> r
      end)
      |> Kernel.++(rows(extra))
      |> Enum.with_index(fn r, seq -> %{r | seq: seq} end)
    end

    defp body(fl), do: IO.iodata_to_binary(fl.body)

    test "under a branch it keeps its own check: no end-of-strip test covers it" do
      with_types(base_types())
      fl = classify(base_text(), arm_rows([]))

      assert fl.test == []
      assert body(fl) =~ "DEFK_FCHECK(DEFK_NONFIN(f_1))"
      refute body(fl) =~ "if (0)"
    end

    test "written twice it is not sticky, and keeps its own check" do
      with_types(base_types())
      rs = base_rows() ++ rows([%{k: :assign, var: "v_acc_2", rhs: "0.0"}])
      fl = classify(base_text() <> "v_acc_2 = 0.0;\n", rs)

      assert fl.test == []
      assert body(fl) =~ "DEFK_FCHECK(DEFK_NONFIN(f_1))"
    end

    test "under a branch, a checked read after the branch still covers it" do
      later = "({ double f_5 = (v_acc_2 + 1.0); DEFK_FCHECK(DEFK_NONFIN(f_5)) { } f_5; })"

      extra = [
        %{k: :ftree, f: "f_5", anchor: "DEFK_FCHECK(DEFK_NONFIN(f_5))", leaves: ["v_acc_2"]},
        %{k: :assign, var: "v_z_5", rhs: later}
      ]

      rs = arm_rows(extra)
      with_types(base_types() ++ [{"v_z_5", "double"}])
      fl = classify(base_text() <> "v_z_5 = #{later};\n", rs)

      assert fl.test == []
      refute body(fl) =~ "DEFK_FCHECK(DEFK_NONFIN(f_1))"
      assert body(fl) =~ "DEFK_FCHECK(DEFK_NONFIN(f_5))"
    end
  end

  test "a float read whose inf reaches a later checked expression is read unchecked" do
    with_types(base_types())
    fl = classify(base_text(), base_rows())

    assert IO.iodata_to_binary(fl.body) =~ "v_y_1 = defk_in_f64_later(ctx,"
  end

  test "the snapshot saves every local, in mention order" do
    with_types(base_types())
    fl = classify(base_text(), base_rows())

    assert IO.iodata_to_binary(fl.snap) ==
             "defk_s7_0 = v_y_1;\ndefk_s7_1 = v_i_0;\ndefk_s7_2 = v_acc_2;\n"
  end

  test "ctx outside the flaggable checks keeps the strip raising" do
    with_types(base_types())
    text = base_text() <> "if (v_y_1 < 0.0) defk_fail(ctx, DEFK_E_ARG, \"neg\");\n"
    assert classify(text, base_rows()) == nil
  end

  test "an array read and written in the strip keeps it raising" do
    with_types(base_types())
    # the write adds its own mention of p_a beside the read's, so not every
    # mention is a write and the snapshot cannot restore the strip
    text = base_text() <> "defk_put_f64(ctx, p_a, v_i_0, v_y_1);\n"
    rs = base_rows() ++ rows([%{k: :elem_write, arr: "p_a", checked: true}])
    assert classify(text, rs) == nil
  end

  describe "joined checks need fixed indices" do
    # a joined check (an i64 helper that can flag) plus an unchecked access
    defp joined_text, do: base_text() <> "v_j_9 = defk_add_i64(ctx, v_i_0, INT64_C(1));\n"

    defp joined_rows(idx) do
      base_rows() ++
        rows([
          %{k: :assign, var: "v_j_9", rhs: "defk_add_i64(ctx, v_i_0, INT64_C(1))"},
          %{k: :access, access: :index, arr: "p_a", idx: idx, support: ["p_a"]}
        ])
    end

    defp joined_types, do: base_types() ++ [{"v_j_9", "int64_t"}]

    test "an index of the loop counter and unwritten values is fixed" do
      with_types(joined_types())
      assert %{joined: true} = classify(joined_text(), joined_rows("v_i_0"))
    end

    test "an index naming a value the strip assigns through a checked helper is not" do
      with_types(joined_types())
      assert classify(joined_text(), joined_rows("v_j_9")) == nil
    end

    # a value the strip assigns once, unconditionally, from fixed values
    # with no checked helper is exact in a flagged run too
    defp fixed_rows(assigns, idx) do
      base_rows() ++
        rows(
          Enum.map(assigns, fn {v, rhs} -> %{k: :assign, var: v, rhs: rhs} end) ++
            [%{k: :access, access: :index, arr: "p_a", idx: idx, support: ["p_a"]}]
        )
    end

    test "an index assigned in the strip from the loop counter by proven arithmetic is fixed" do
      with_types(joined_types())
      rs = fixed_rows([{"v_j_9", "(v_i_0 + INT64_C(1))"}], "v_j_9")
      assert %{joined: true} = classify(joined_text(), rs)
    end

    test "through another fixed value too" do
      with_types(joined_types() ++ [{"v_k_10", "int64_t"}])

      rs =
        fixed_rows(
          [{"v_j_9", "(v_i_0 * INT64_C(2))"}, {"v_k_10", "(v_j_9 - INT64_C(1))"}],
          "v_k_10"
        )

      assert %{joined: true} = classify(joined_text(), rs)
    end

    test "an index assigned from an array read is not" do
      with_types(joined_types())
      rs = fixed_rows([{"v_j_9", "(p_a).data[v_i_0]"}], "v_j_9")
      assert classify(joined_text(), rs) == nil
    end

    test "an index assigned from a value that can overflow under the flag is not" do
      with_types(joined_types() ++ [{"v_k_10", "int64_t"}])

      rs =
        fixed_rows(
          [
            {"v_k_10", "defk_mul_i64(ctx, v_i_0, INT64_C(3))"},
            {"v_j_9", "(v_k_10 & INT64_C(7))"}
          ],
          "v_j_9"
        )

      assert classify(joined_text(), rs) == nil
    end

    test "an index assigned from a non-fixed helper, conditionally, twice or from itself is not" do
      with_types(joined_types())

      for assigns <- [
            [{"v_j_9", "defk_div_i64(ctx, v_i_0, INT64_C(2))"}],
            [{"v_j_9", "(v_j_9 + INT64_C(1))"}],
            [{"v_j_9", "(v_i_0 + INT64_C(1))"}, {"v_j_9", "(v_i_0 + INT64_C(2))"}]
          ] do
        assert classify(joined_text(), fixed_rows(assigns, "v_j_9")) == nil
      end

      conditional =
        base_rows() ++
          rows([
            %{k: :assign, var: "v_j_9", rhs: "(v_i_0 + INT64_C(1))", cond: true},
            %{k: :access, access: :index, arr: "p_a", idx: "v_j_9", support: ["p_a"]}
          ])

      assert classify(joined_text(), conditional) == nil

      in_arm =
        base_rows() ++
          rows([
            %{k: :assign, var: "v_j_9", rhs: "(v_i_0 + INT64_C(1))", path: [{make_ref(), 0}]},
            %{k: :access, access: :index, arr: "p_a", idx: "v_j_9", support: ["p_a"]}
          ])

      assert classify(joined_text(), in_arm) == nil
    end

    test "a word load's pointer form is never fixed" do
      with_types(joined_types())

      rs =
        base_rows() ++
          rows([
            %{k: :assign, var: "v_j_9", rhs: "defk_add_i64(ctx, v_i_0, INT64_C(1))"},
            %{k: :access, access: :load, arr: "p_a", idx: "v_i_0", support: ["p_a"]}
          ])

      assert classify(joined_text(), rs) == nil
    end
  end

  describe "what counts as still holding its value (the branch paths)" do
    # y read in one arm; a sibling arm's write of y runs instead, so the
    # read still reaches the copy after the branch
    test "a sibling arm's write does not break the chain" do
      ref = make_ref()

      rs =
        rows([
          %{k: :assign, var: "v_y_1", rhs: @read, path: [{ref, 0}]},
          %{k: :assign, var: "v_y_1", rhs: "0.0", path: [{ref, 1}]},
          %{k: :assign, var: "v_c_3", rhs: "v_y_1"},
          %{k: :ftree, f: "f_1", anchor: "DEFK_FCHECK(DEFK_NONFIN(f_1))", leaves: ["v_c_3"]},
          %{k: :assign, var: "v_acc_2", rhs: @tree},
          %{k: :assign, var: "v_i_0", rhs: "v_i_0 + step"}
        ])

      text =
        "if (v_i_0 > 0) {\nv_y_1 = #{@read};\n} else {\nv_y_1 = 0.0;\n}\n" <>
          "v_c_3 = v_y_1;\nv_acc_2 = #{@tree};\nv_i_0 += 1;\n"

      with_types(base_types() ++ [{"v_c_3", "double"}])
      fl = classify(text, rs)
      assert IO.iodata_to_binary(fl.body) =~ "defk_in_f64_later"
    end

    test "an unconditional later write of y breaks it" do
      rs =
        rows([
          %{k: :assign, var: "v_y_1", rhs: @read},
          %{k: :assign, var: "v_y_1", rhs: "0.0"},
          %{k: :assign, var: "v_c_3", rhs: "v_y_1"},
          %{k: :ftree, f: "f_1", anchor: "DEFK_FCHECK(DEFK_NONFIN(f_1))", leaves: ["v_c_3"]},
          %{k: :assign, var: "v_acc_2", rhs: @tree},
          %{k: :assign, var: "v_i_0", rhs: "v_i_0 + step"}
        ])

      text =
        "v_y_1 = #{@read};\nv_y_1 = 0.0;\nv_c_3 = v_y_1;\n" <>
          "v_acc_2 = #{@tree};\nv_i_0 += 1;\n"

      with_types(base_types() ++ [{"v_c_3", "double"}])
      fl = classify(text, rs)
      refute IO.iodata_to_binary(fl.body) =~ "defk_in_f64_later"
    end
  end
end
