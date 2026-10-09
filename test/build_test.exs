defmodule Defk.BuildTest do
  use ExUnit.Case, async: true

  @env %{erts: "15.2.1", cc: "cc", cc_version: "Apple clang version 17.0.0"}
  @src "int f(void) { return 1; }"

  test "identical inputs give the same 10-hex-char key" do
    key = Defk.Build.cache_key(@src, @env)
    assert key == Defk.Build.cache_key(@src, @env)
    assert key =~ ~r/\A[0-9a-f]{10}\z/
  end

  test "changing the ERTS version changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | erts: "16.0"})
  end

  test "changing the compiler changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | cc: "gcc"})
  end

  test "changing the compiler version changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | cc_version: "gcc 14.1"})
  end

  test "changing the source changes the key" do
    refute Defk.Build.cache_key(@src, @env) == Defk.Build.cache_key(@src <> " ", @env)
  end

  test "the convenience wrapper is stable within a run" do
    assert Defk.Build.cache_key(@src) == Defk.Build.cache_key(@src)
  end
end
