Code.compile_string("""
defmodule RT.K do
  use Defk
  defk f(a :: i64, b :: i64) :: i64, do: a + b
end
""")

IO.puts("RESULT #{RT.K.f(2, 3)} #{RT.K.__defk_lib__()}")
