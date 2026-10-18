defmodule DefkTest do
  use ExUnit.Case, async: true

  # assert_agrees/3,4 itself is a promise, tested as public API I9
  # (test/contracts/defk/test_helpers_contract_test.exs); here, the mapping
  # of the runtime's message templates to agreement reasons
  test "Defk.Test.agreement_reason/1 normalises the kernel's and Elixir mode's messages" do
    reasons = [
      {%ArithmeticError{message: "i64 overflow in 3 * 4"}, :overflow},
      {%ArithmeticError{message: "trunc/1: 9.22337e+18 does not fit in i64"}, :overflow},
      {%ArithmeticError{message: "div/2 by zero"}, :zero_divisor},
      {%ArithmeticError{message: "bad argument in arithmetic expression"}, :non_finite},
      {%ArithmeticError{message: "bad argument in arithmetic expression: division by zero"},
       :non_finite},
      {%ArithmeticError{message: "kernel produced a non-finite float"}, :non_finite},
      # the messages as the runtime raises them (Defk.Messages), whole: a
      # reason comes from the template a message was raised with
      {%ArithmeticError{
         message:
           "range element 9 is within one step of the i64 limit (stepping past it overflows)"
       }, :range_limit},
      {%ArgumentError{message: "argument 2 (step) must be an integer fitting in i64"}, :badarg},
      {%ArgumentError{
         message: "non-finite float (inf or NaN) read from an input array at index 0"
       }, :non_finite_input},
      {%ArgumentError{message: "alloc/2: length too large"}, :length_too_large},
      {%ArgumentError{message: "out of memory (allocating 8 bytes)"}, :out_of_memory},
      # the owned-buffer budget, the same message in both modes
      {%ArgumentError{
         message:
           "out of memory (allocating 1024 bytes would take this call's buffers past max_owned_bytes, 8192 bytes)"
       }, :out_of_memory},
      {%Enum.OutOfBoundsError{message: "index 3 out of bounds"}, :index},
      {%CaseClauseError{term: 3}, :clause},
      {%RuntimeError{message: "defk bug"}, {:other, "defk bug"}}
    ]

    for {e, reason} <- reasons, do: assert(Defk.Test.agreement_reason(e) == reason, inspect(e))
  end
end
