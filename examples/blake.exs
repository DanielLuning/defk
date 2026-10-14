# blake: BLAKE2b (RFC 7693) and BLAKE3 written from scratch as kernels,
# against pure Elixir, :crypto, blake2_elixir (C NIF) and blake3 (Rust NIF)
#
# Why people reach for a NIF here: content hashing and dedup (file and chunk
# digests, content-addressed stores), and BLAKE2b inside libsodium, Argon2,
# Zcash and IPFS. Both hashes are plain loops of adds, xors and rotates over
# small states with published test vectors, so they can be written from
# scratch. BLAKE2b works on 64-bit words, which are bignums in Elixir above
# 2^59; BLAKE3 works on 32-bit words, which stay small integers.
#
# The packages (the ticket named b3 a Rustler NIF; it is pure Elixir):
#   blake2 1.0.4         pure Elixir BLAKE2b/2s (RFC 7693), Hex
#   blake2_elixir 0.9.0  C NIF over the BLAKE2 reference C (blake2b.c, -O3,
#                        elixir_make), normal scheduler, returns a list
#   b3 0.2.1             pure Elixir BLAKE3, already tuned for the BEAM
#                        (macro-unrolled G on bare variables)
#   blake3 1.0.2         Rustler NIF over the blake3 crate 1.3.3, normal
#                        scheduler; on aarch64 the crate builds its NEON code
#                        by default (build.rs), so this is the SIMD build
# Build notes for Mix.install: blake3 1.0.2 needs rustler 0.30 (0.31+ runs
# `cargo -p blake3`, ambiguous with the crate of the same name), and blake2
# and blake2_elixir both define Blake2.Mixfile and Blake2, so blake2 is fetched
# with `compile: false` and compiled here as HexBlake2.
#
# Expected verdicts (pre-registered in defk-52v.2): good against pure Elixir
# for both; marginal against :crypto's blake2b; poor against blake3's SIMD
# build, parity with BLAKE3's portable C. All four held (numbers below).
#
#   elixir examples/blake.exs                    # agreement + three reports
#   BLAKE_VARIANTS=1 elixir examples/blake.exs   # also every Elixir variant
#
# DEFK_RESULT lines, in this order (mix defk.examples reads the first; the script
# checks the other two itself and exits 1 when one fails):
#   1. blake         BLAKE2b-512 of one 64 KB message: defk vs the best pure
#                    Elixir; blake2_elixir reported as `native`
#   2. blake_crypto  the same against :crypto.hash(:blake2b, _), the Elixir
#                    answer for BLAKE2b (marginal or poor both mean "use :crypto")
#   3. blake3        BLAKE3 of one 64 KB message: defk vs the best pure Elixir;
#                    the blake3 NIF (NEON) reported as `native`
#
# The kernels: blake2b(msg, outlen) and blake2b_keyed(msg, key, outlen)
# (RFC 7693, key 0..64 bytes, digest 1..64 bytes); blake3(msg) and
# blake3_keyed(msg, key) (32-byte key), 32-byte output. The compression
# functions are helper kernels returning the 8 new state words as a tuple
# (b2b_compress, b3_block, b3_parent); they are inlined at each call site.
# Rounds are fully unrolled: Blake.Gen writes them from the RFC's SIGMA table
# and BLAKE3's MSG_PERMUTATION (module attributes of Blake.Gen), with the
# message words as 16 locals loaded by u64_le/u32_le, so the schedule is
# literal variable names, as in the reference C's ROUND macros. The same
# generator writes the Elixir versions' rounds. BLAKE2b keeps words as u64
# bit patterns in i64 (wrap64 adds, rotr); BLAKE3 keeps 32-bit words below
# 2^32 (adds under a 32-bit mask, rotr(x, n, 32)). The IVs are a binary
# attribute (BLAKE2b, read with u64_le) or literals. BLAKE3's tree is
# iterative over an alloc'd stack of 54 CVs: after full chunk c, ctz(c + 1)
# merges (a `for` over 1..ctz(c + 1)//1, so no while loop is needed), and at
# the end the last chunk's CV is folded into the stack from the top with
# ROOT on the last parent. The last (partial) block of each hash is copied
# into a zero-padded alloc'd block.
#
# Agreement, checked on every run: RFC 7693 Appendix A (BLAKE2b-512("abc"))
# and the Appendix E self-test (the BLAKE2b-256 of 48 unkeyed and keyed
# digests at 6 lengths x 4 digest lengths, c23a7800...), for the kernel and
# both Elixir versions; the official BLAKE3 test vectors
# (test_vectors/test_vectors.json of BLAKE3-team/BLAKE3, 35 lengths 0..102400
# over 3 tree levels, hash and keyed_hash, first 32 bytes) for the kernels,
# this file's Elixir and b3; 661 random messages (every length 0..600, then
# 60 up to 20 KB) with random keys (0..64 bytes) and digest lengths against
# :crypto, blake2_elixir, the blake3 NIF (hash and keyed_hash), blake2 and
# b3; bad arguments (digest length 0 or 65, a 65-byte key, a 31-byte BLAKE3
# key) raise ArgumentError; and Elixir mode, compiled from the same quoted
# kernels under a throwaway Mix project in :test, equals the kernels on 138
# messages for all four kernels and raises the same errors.
#
# Elixir baselines: optimised. BLAKE2b-512, 64 KB (best of 5 interleaved
# rounds, under load):
#
#   blake2 1.0.4 (pure Elixir, Hex; lists, Tuple.insert_at)  31-67 ms
#   Blake.Elixir2b64: unsigned 64-bit words, unrolled         14.4-14.6 ms (first pass)
#   Blake.Elixir2b: each word as two 32-bit halves, unrolled  1.37-1.43 ms
#   defk blake2b                                              0.042-0.049 ms
#   :crypto.hash(:blake2b, _) (OpenSSL)                       0.050-0.064 ms
#   blake2_elixir (reference C NIF)                           0.043-0.046 ms
#
# The halves are the one big step (10x): a 64-bit add is a low add, a carry
# (bsr(t, 32)) and a high add, rotr 32 swaps the halves, rotr 24/16/63 take
# bits across from the other half; nothing allocates. BLAKE3, 64 KB (best of
# 9 interleaved rounds):
#
#   b3 0.2.1 (pure Elixir, Hex)                               0.598-0.632 ms
#   Blake.Elixir3: one pass, no structs, list CV stack        0.562-0.583 ms
#   defk blake3                                               0.054-0.055 ms
#   blake3 (Rust NIF, NEON)                                   0.033 ms
#
# b3 is close to what Elixir can do; this file's loop only drops b3's
# per-chunk struct updates (5-10%). Not tried: hashing BLAKE3's subtrees in
# parallel tasks (the tree allows it on both sides, so the ratio would stay
# about the same, and short kernel tasks stay on few schedulers, defk-8qs);
# lazy masking in the halves (letting a half grow past 32 bits between
# masks).
#
# Kernel variants: a BLAKE2b round loop reading SIGMA from a binary attribute
# (`mw[@sigma[16 * r + i]]`, message words in an alloc'd [i64]) took 48-49
# us at 64 KB against 43 us unrolled (12% slower, before its last-block
# handling). BLAKE3's rotate as the masked spelling
# band(bsr(x, n) + bsl(x, 32 - n), 0xFFFFFFFF) took 79-80 us: clang emits a
# shift and a bit-field insert on a 64-bit register, not a ror. rotr(x, n,
# 32) was slower still (95-98 us) until this ticket made the runtime rotate a
# 32-bit field as a uint32_t (priv/defk_runtime.h, defk_rot_w): then 54-55
# us, one `ror w` per rotate, level with the portable C.
#
# Native, 64 MB (best of 3 interleaved rounds): defk blake2b 43.2-43.8 ms
# (1.54 GB/s), blake2_elixir 44.4-44.7 ms, :crypto 50.1-51.2 ms; defk blake3
# 54.9-55.7 ms (1.21 GB/s), blake3 NIF (NEON) 33.7-34.0 ms. BLAKE3's
# portable C measured outside the BEAM (the crate's c/ directory, clang -O3,
# blake3.c + blake3_dispatch.c + blake3_portable.c with BLAKE3_USE_NEON=0,
# best of 200 / 5): 52 us at 64 KB, 54.9-55.1 ms at 64 MB; with
# blake3_neon.c: 31 us, 33.6 ms. Tick gaps (1 ms ticker on one scheduler,
# one 64 MB hash): both NIFs block their scheduler for the whole hash
# (BLAKE2b 45-49 ms, BLAKE3 34-37 ms); the kernels yield (2.1-2.7 ms, the
# loaded ticker's floor); pure Elixir 2.7-3.6 ms (BLAKE3) and 10-11 ms
# (BLAKE2b halves; not investigated). Speedups over the optimised Elixir:
# BLAKE2b 31.8-32.7x at 64 KB, 32.5-33.3x at 64 MB, 21-22x at 1 KB; BLAKE3
# 10.6-10.9x at 64 KB, 10.1x at 64 MB, 8-9x at 1 KB; against :crypto
# 1.16-1.19x (1.0x at 1 KB).
#
# NUMBERS ARE PROVISIONAL: measured on a loaded machine (other agents' mix
# ci, benchmarks and stress runs; 1-minute load averages 13-135 on 12 cores).

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:blake2_elixir, "~> 0.9.0"},
  # pure Elixir BLAKE2b; its mix.exs and module share names with
  # blake2_elixir's (Blake2.Mixfile, Blake2), so it is fetched only and
  # compiled below under another name
  {:blake2, "~> 1.0", compile: false, app: false},
  {:b3, "~> 0.2.1"},
  {:blake3, "~> 1.0"},
  # blake3 1.0.2's crate is itself named blake3; rustler 0.31+ builds it with
  # `cargo -p blake3`, which is ambiguous, so keep the rustler it was made for
  {:rustler, "~> 0.30.0", override: true}
])

# The blake2 package (pure Elixir) compiled as HexBlake2
Path.join(Mix.install_project_dir(), "deps/blake2/lib/blake2.ex")
|> File.read!()
|> String.replace("defmodule Blake2 do", "defmodule HexBlake2 do")
|> then(&Code.with_diagnostics(fn -> Code.compile_string(&1) end))

defmodule Blake.Gen do
  @moduledoc """
  The constants of both hashes and the generators of their unrolled rounds.
  The same round generator writes the kernels' rounds and the Elixir
  versions' rounds, so both sides run the same operations in the same order.
  """
  import Bitwise

  # RFC 7693 2.6 (the SHA-512 IV) and 2.7 (the message schedule SIGMA)
  @iv2b [
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179
  ]
  @sigma [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
  ]
  # BLAKE3 spec 2.2: the IV is SHA-256's (the high halves of BLAKE2b's), and
  # the message words are permuted by MSG_PERMUTATION between rounds
  @perm3 [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
  # G's four state words: four columns, then four diagonals (both hashes)
  @g [
    {0, 4, 8, 12},
    {1, 5, 9, 13},
    {2, 6, 10, 14},
    {3, 7, 11, 15},
    {0, 5, 10, 15},
    {1, 6, 11, 12},
    {2, 7, 8, 13},
    {3, 4, 9, 14}
  ]

  def iv2b, do: @iv2b
  def iv3, do: Enum.map(@iv2b, &bsr(&1, 32))

  @doc "BLAKE2b's 12 rounds of message indices: SIGMA[0..9], then SIGMA[0..1] again."
  def schedule2b, do: @sigma ++ Enum.take(@sigma, 2)

  @doc "BLAKE3's 7 rounds of message indices: the identity, permuted once per round."
  def schedule3 do
    Enum.scan(1..6, Enum.to_list(0..15), fn _, s -> Enum.map(@perm3, &Enum.at(s, &1)) end)
    |> then(&[Enum.to_list(0..15) | &1])
  end

  def var(name), do: Macro.var(name, nil)
  def vs(prefix, n), do: for(i <- 0..(n - 1), do: var(:"#{prefix}#{i}"))

  @doc """
  The rounds as a list of statements over the state words v0..v15 and the
  message words m0..m15; `g` gives the statements of one G call.
  """
  def rounds(schedule, g) do
    for row <- schedule,
        {{a, b, c, d}, i} <- Enum.with_index(@g),
        stmt <-
          g.(
            var(:"v#{a}"),
            var(:"v#{b}"),
            var(:"v#{c}"),
            var(:"v#{d}"),
            var(:"m#{Enum.at(row, 2 * i)}"),
            var(:"m#{Enum.at(row, 2 * i + 1)}")
          ),
        do: stmt
  end

  @doc "BLAKE2b's G in a kernel: u64 bit patterns in i64, wrapping adds, rotr."
  def g2b_kernel(a, b, c, d, x, y) do
    [
      quote(do: unquote(a) = wrap64(unquote(a) + unquote(b) + unquote(x))),
      quote(do: unquote(d) = rotr(bxor(unquote(d), unquote(a)), 32)),
      quote(do: unquote(c) = wrap64(unquote(c) + unquote(d))),
      quote(do: unquote(b) = rotr(bxor(unquote(b), unquote(c)), 24)),
      quote(do: unquote(a) = wrap64(unquote(a) + unquote(b) + unquote(y))),
      quote(do: unquote(d) = rotr(bxor(unquote(d), unquote(a)), 16)),
      quote(do: unquote(c) = wrap64(unquote(c) + unquote(d))),
      quote(do: unquote(b) = rotr(bxor(unquote(b), unquote(c)), 63))
    ]
  end

  @m64 0xFFFFFFFFFFFFFFFF
  defp rotr64e(x, n),
    do:
      quote(
        do:
          bor(bsr(unquote(x), unquote(n)), band(bsl(unquote(x), unquote(64 - n)), unquote(@m64)))
      )

  @doc "BLAKE2b's G in plain Elixir on unsigned 64-bit integers (bignums above 2^59)."
  def g2b_elixir64(a, b, c, d, x, y) do
    [
      quote(do: unquote(a) = band(unquote(a) + unquote(b) + unquote(x), unquote(@m64))),
      quote(do: unquote(d) = unquote(rotr64e(quote(do: bxor(unquote(d), unquote(a))), 32))),
      quote(do: unquote(c) = band(unquote(c) + unquote(d), unquote(@m64))),
      quote(do: unquote(b) = unquote(rotr64e(quote(do: bxor(unquote(b), unquote(c))), 24))),
      quote(do: unquote(a) = band(unquote(a) + unquote(b) + unquote(y), unquote(@m64))),
      quote(do: unquote(d) = unquote(rotr64e(quote(do: bxor(unquote(d), unquote(a))), 16))),
      quote(do: unquote(c) = band(unquote(c) + unquote(d), unquote(@m64))),
      quote(do: unquote(b) = unquote(rotr64e(quote(do: bxor(unquote(b), unquote(c))), 63)))
    ]
  end

  @doc """
  BLAKE2b's G in plain Elixir on 32-bit halves: word vI is vIh (high) and
  vIl (low), every value stays a small integer. A 64-bit add carries the low
  sum's bit 32 into the high half; rotr 32 swaps the halves; rotr 24 and 16
  take bits across from the other half; rotr 63 is a rotl 1.
  """
  def g2b_halves(a, b, c, d, x, y) do
    [ah, bh, ch, dh, xh, yh] = Enum.map([a, b, c, d, x, y], &half(&1, "h"))
    [al, bl, cl, dl, xl, yl] = Enum.map([a, b, c, d, x, y], &half(&1, "l"))
    t = var(:t)
    u = var(:u)

    add3 = fn {rh, rl}, {ph, pl}, {qh, ql} ->
      [
        quote(do: unquote(t) = unquote(rl) + unquote(pl) + unquote(ql)),
        quote(
          do:
            unquote(rh) =
              band(unquote(rh) + unquote(ph) + unquote(qh) + bsr(unquote(t), 32), 0xFFFFFFFF)
        ),
        quote(do: unquote(rl) = band(unquote(t), 0xFFFFFFFF))
      ]
    end

    add2 = fn {rh, rl}, {ph, pl} ->
      [
        quote(do: unquote(t) = unquote(rl) + unquote(pl)),
        quote(
          do: unquote(rh) = band(unquote(rh) + unquote(ph) + bsr(unquote(t), 32), 0xFFFFFFFF)
        ),
        quote(do: unquote(rl) = band(unquote(t), 0xFFFFFFFF))
      ]
    end

    # r = rotr(r ^ p, n) for 0 < n < 32 on halves, through the temps t, u
    rot = fn {rh, rl}, {ph, pl}, n ->
      [
        quote(do: unquote(t) = bxor(unquote(rh), unquote(ph))),
        quote(do: unquote(u) = bxor(unquote(rl), unquote(pl))),
        quote(
          do:
            unquote(rh) =
              band(bsr(unquote(t), unquote(n)) + bsl(unquote(u), unquote(32 - n)), 0xFFFFFFFF)
        ),
        quote(
          do:
            unquote(rl) =
              band(bsr(unquote(u), unquote(n)) + bsl(unquote(t), unquote(32 - n)), 0xFFFFFFFF)
        )
      ]
    end

    swap = fn {rh, rl}, {ph, pl} ->
      [
        quote(do: unquote(t) = bxor(unquote(rh), unquote(ph))),
        quote(do: unquote(rh) = bxor(unquote(rl), unquote(pl))),
        quote(do: unquote(rl) = unquote(t))
      ]
    end

    # rotl 1 = rotr 63
    rotl1 = fn {rh, rl}, {ph, pl} ->
      [
        quote(do: unquote(t) = bxor(unquote(rh), unquote(ph))),
        quote(do: unquote(u) = bxor(unquote(rl), unquote(pl))),
        quote(do: unquote(rh) = band(bsl(unquote(t), 1) + bsr(unquote(u), 31), 0xFFFFFFFF)),
        quote(do: unquote(rl) = band(bsl(unquote(u), 1) + bsr(unquote(t), 31), 0xFFFFFFFF))
      ]
    end

    {a, b, c, d, x, y} = {{ah, al}, {bh, bl}, {ch, cl}, {dh, dl}, {xh, xl}, {yh, yl}}

    add3.(a, b, x) ++
      swap.(d, a) ++
      add2.(c, d) ++
      rot.(b, c, 24) ++
      add3.(a, b, y) ++ rot.(d, a, 16) ++ add2.(c, d) ++ rotl1.(b, c)
  end

  defp half({name, _, _}, suffix), do: var(:"#{name}#{suffix}")

  @doc """
  BLAKE3's G on 32-bit words in integers below 2^32, adds under a 32-bit
  mask. The rotate right by a literal n is the builtin `rotr(x, n, 32)` in a
  kernel (one `ror` on a 32-bit register) and
  `band(bsr(x, n) + bsl(x, 32 - n), 0xFFFFFFFF)` in plain Elixir (the two
  parts share no bits, so + is the bor). In a kernel the masked spelling is
  wrapped arithmetic too, but clang gives it a shift and a bit-field insert
  on a 64-bit register, not a ror: 79-80 us at 64 KB against 54-55 us.
  """
  def g3(a, b, c, d, x, y, kernel? \\ false) do
    rot = fn r, p, n ->
      [
        quote(do: unquote(r) = bxor(unquote(r), unquote(p))),
        if kernel? do
          quote(do: unquote(r) = rotr(unquote(r), unquote(n), 32))
        else
          quote(
            do:
              unquote(r) =
                band(bsr(unquote(r), unquote(n)) + bsl(unquote(r), unquote(32 - n)), 0xFFFFFFFF)
          )
        end
      ]
    end

    [quote(do: unquote(a) = band(unquote(a) + unquote(b) + unquote(x), 0xFFFFFFFF))] ++
      rot.(d, a, 16) ++
      [quote(do: unquote(c) = band(unquote(c) + unquote(d), 0xFFFFFFFF))] ++
      rot.(b, c, 12) ++
      [quote(do: unquote(a) = band(unquote(a) + unquote(b) + unquote(y), 0xFFFFFFFF))] ++
      rot.(d, a, 8) ++
      [quote(do: unquote(c) = band(unquote(c) + unquote(d), 0xFFFFFFFF))] ++
      rot.(b, c, 7)
  end
end

alias Blake.Gen

# ---- the kernels ---------------------------------------------------------------
# Quoted once and compiled twice: as Blake.Kernels (native, the one measured)
# and as Blake.ElixirMode (Elixir mode, for the agreement check at the end).
iv2b = Enum.map(Gen.iv2b(), &Defk.Bits.wrap64/1)
iv3 = Gen.iv3()
[h, m, c, k, l, r, x, y] = for p <- ~w(h m c k l r x y)a, do: Gen.vs(p, 16)
i64s = fn n -> List.duplicate(quote(do: i64), n) end
typed = fn vars -> Enum.map(vars, &quote(do: unquote(&1) :: i64)) end
tuple_t = fn n -> {:{}, [], i64s.(n)} end

kernels =
  quote do
    use Defk

    # BLAKE2b's IV as a binary attribute, read with u64_le(@iv2b, 8 * i)
    @iv2b for w <- Blake.Gen.iv2b(), into: <<>>, do: <<w::little-64>>

    defk blake2b(msg :: [u8], outlen :: i64) :: [u8] do
      blake2b_keyed(msg, "", outlen)
    end

    # RFC 7693 with an optional key (0..64 bytes) and digest length 1..64.
    # The stream is the key block (when keyed), then the message; every block
    # but the last is compressed straight from its source, the last one from
    # a zero-padded copy.
    defk blake2b_keyed(msg :: [u8], key :: [u8], outlen :: i64) :: [u8] do
      if outlen < 1 or outlen > 64, do: raise(ArgumentError, "outlen must be in 1..64")
      kk = length(key)
      if kk > 64, do: raise(ArgumentError, "key must be at most 64 bytes")
      ll = length(msg)
      kb = if kk > 0, do: 1, else: 0
      total = 128 * kb + ll
      nb = max(div(total + 127, 128), 1)

      keyblk = alloc(u8, 128)

      for i <- 0..(kk - 1)//1 do
        keyblk[i] = key[i]
      end

      # the last block: from stream offset 128 * (nb - 1), zero padded
      lstart = 128 * (nb - 1)
      lastblk = alloc(u8, 128)

      for i <- 0..(total - lstart - 1)//1 do
        lastblk[i] = if kb == 1 and nb == 1, do: keyblk[i], else: msg[lstart - 128 * kb + i]
      end

      unquote_splicing(
        for i <- 0..7 do
          init =
            if i == 0,
              do: quote(do: bxor(u64_le(@iv2b, 0), 0x01010000 + 256 * kk + outlen)),
              else: quote(do: u64_le(@iv2b, unquote(8 * i)))

          quote(do: unquote(Enum.at(h, i)) = unquote(init))
        end
      )

      # the key block, when it is not also the last
      {unquote_splicing(Enum.take(h, 8))} =
        for _ <- 1..(kb * min(nb - 1, 1))//1, reduce: {unquote_splicing(Enum.take(h, 8))} do
          {unquote_splicing(Enum.take(h, 8))} ->
            b2b_compress(unquote_splicing(Enum.take(h, 8)), keyblk, 0, 128, 0)
        end

      {unquote_splicing(Enum.take(h, 8))} =
        for b <- kb..(nb - 2)//1, reduce: {unquote_splicing(Enum.take(h, 8))} do
          {unquote_splicing(Enum.take(h, 8))} ->
            b2b_compress(unquote_splicing(Enum.take(h, 8)), msg, 128 * (b - kb), 128 * (b + 1), 0)
        end

      {unquote_splicing(Enum.take(h, 8))} =
        b2b_compress(unquote_splicing(Enum.take(h, 8)), lastblk, 0, total, -1)

      full = alloc(u8, 64)

      for j <- 0..7//1 do
        (unquote_splicing(
           for i <- 0..7 do
             quote(do: full[unquote(8 * i) + j] = band(bsr(unquote(Enum.at(h, i)), 8 * j), 255))
           end
         ))
      end

      out = alloc(u8, outlen)

      for i <- 0..(outlen - 1)//1 do
        out[i] = full[i]
      end

      out
    end

    # F (RFC 7693 3.2): the 128-byte block at src[off..], byte counter t (it
    # stays below 2^61, so its high word is 0), last = -1 for the final block
    defk b2b_compress(
           unquote_splicing(typed.(Enum.take(h, 8))),
           src :: [u8],
           off :: i64,
           t :: i64,
           last :: i64
         ) :: unquote(tuple_t.(8)) do
      unquote_splicing(
        for i <- 0..15, do: quote(do: unquote(Enum.at(m, i)) = u64_le(src, off + unquote(8 * i)))
      )

      unquote_splicing(
        for i <- 0..15 do
          v = Gen.var(:"v#{i}")

          val =
            case i do
              i when i < 8 -> Enum.at(h, i)
              12 -> quote(do: bxor(unquote(Enum.at(iv2b, 4)), t))
              14 -> quote(do: bxor(unquote(Enum.at(iv2b, 6)), last))
              i -> Enum.at(iv2b, i - 8)
            end

          quote(do: unquote(v) = unquote(val))
        end
      )

      unquote_splicing(Gen.rounds(Gen.schedule2b(), &Gen.g2b_kernel/6))

      {unquote_splicing(
         for i <- 0..7,
             do:
               quote(
                 do:
                   bxor(
                     bxor(unquote(Enum.at(h, i)), unquote(Gen.var(:"v#{i}"))),
                     unquote(Gen.var(:"v#{i + 8}"))
                   )
               )
       )}
    end

    # ---- BLAKE3 ----

    defk blake3(msg :: [u8]) :: [u8] do
      blake3_core(msg, unquote_splicing(iv3), 0)
    end

    # keyed_hash mode: the key's 8 little-endian words replace the IV
    defk blake3_keyed(msg :: [u8], key :: [u8]) :: [u8] do
      if length(key) != 32, do: raise(ArgumentError, "key must be 32 bytes")

      blake3_core(
        msg,
        unquote_splicing(for i <- 0..7, do: quote(do: u32_le(key, unquote(4 * i)))),
        16
      )
    end

    # The tree: every full chunk but the last is hashed to a chaining value
    # (CV) and pushed on a stack of CVs; after chunk c, ctz(c + 1) pairs are
    # merged into parents (the count of trailing zero bits of the chunk count
    # is the number of completed subtrees). The last chunk's CV is then folded
    # into the stack from the top, and the last compression gets ROOT.
    # Flags: CHUNK_START 1, CHUNK_END 2, PARENT 4, ROOT 8, KEYED_HASH 16.
    defk blake3_core(msg :: [u8], unquote_splicing(typed.(Enum.take(k, 8))), flags :: i64) ::
           [u8] do
      n = length(msg)
      nc = max(div(n + 1023, 1024), 1)
      # 54 levels are enough for 2^64 bytes
      stack0 = alloc(i64, 8 * 54)

      {stack, sp} =
        for ci <- 0..(nc - 2)//1, reduce: {stack0, 0} do
          {stack, sp} ->
            {unquote_splicing(Enum.take(x, 8))} =
              for b <- 0..15//1, reduce: {unquote_splicing(Enum.take(k, 8))} do
                {unquote_splicing(Enum.take(x, 8))} ->
                  fl = flags + if(b == 0, do: 1, else: 0) + if(b == 15, do: 2, else: 0)

                  b3_block(
                    unquote_splicing(Enum.take(x, 8)),
                    msg,
                    1024 * ci + 64 * b,
                    ci,
                    64,
                    fl
                  )
              end

            {unquote_splicing(Enum.take(x, 8)), sp} =
              for _ <- 1..ctz(ci + 1)//1, reduce: {unquote_splicing(Enum.take(x, 8)), sp} do
                {unquote_splicing(Enum.take(x, 8)), sp} ->
                  p = 8 * (sp - 1)

                  {unquote_splicing(Enum.take(y, 8))} =
                    b3_parent(
                      unquote_splicing(for i <- 0..7, do: quote(do: stack[p + unquote(i)])),
                      unquote_splicing(Enum.take(x, 8)),
                      unquote_splicing(Enum.take(k, 8)),
                      flags + 4
                    )

                  {unquote_splicing(Enum.take(y, 8)), sp - 1}
              end

            unquote_splicing(
              for i <- 0..7,
                  do: quote(do: stack[8 * sp + unquote(i)] = unquote(Enum.at(x, i)))
            )

            {stack, sp + 1}
        end

      # the last chunk: full blocks from msg, the last block from a padded copy
      cstart = 1024 * (nc - 1)
      rem = n - cstart
      nbl = max(div(rem + 63, 64), 1)
      bstart = cstart + 64 * (nbl - 1)
      lastblk = alloc(u8, 64)

      for i <- 0..(n - bstart - 1)//1 do
        lastblk[i] = msg[bstart + i]
      end

      {unquote_splicing(Enum.take(x, 8))} =
        for b <- 0..(nbl - 2)//1, reduce: {unquote_splicing(Enum.take(k, 8))} do
          {unquote_splicing(Enum.take(x, 8))} ->
            fl = flags + if(b == 0, do: 1, else: 0)
            b3_block(unquote_splicing(Enum.take(x, 8)), msg, cstart + 64 * b, nc - 1, 64, fl)
        end

      root = if sp == 0, do: 8, else: 0
      fl = flags + 2 + root + if(nbl == 1, do: 1, else: 0)

      {unquote_splicing(Enum.take(x, 8))} =
        b3_block(unquote_splicing(Enum.take(x, 8)), lastblk, 0, nc - 1, n - bstart, fl)

      {unquote_splicing(Enum.take(x, 8))} =
        for i <- (sp - 1)..0//-1, reduce: {unquote_splicing(Enum.take(x, 8))} do
          {unquote_splicing(Enum.take(x, 8))} ->
            p = 8 * i

            b3_parent(
              unquote_splicing(for j <- 0..7, do: quote(do: stack[p + unquote(j)])),
              unquote_splicing(Enum.take(x, 8)),
              unquote_splicing(Enum.take(k, 8)),
              flags + 4 + if(i == 0, do: 8, else: 0)
            )
        end

      out = alloc(u8, 32)

      for j <- 0..3//1 do
        (unquote_splicing(
           for i <- 0..7 do
             quote(do: out[unquote(4 * i) + j] = band(bsr(unquote(Enum.at(x, i)), 8 * j), 255))
           end
         ))
      end

      out
    end

    # The compression of one 64-byte block at src[off..], to a CV
    defk b3_block(
           unquote_splicing(typed.(Enum.take(c, 8))),
           src :: [u8],
           off :: i64,
           counter :: i64,
           blen :: i64,
           flags :: i64
         ) :: unquote(tuple_t.(8)) do
      unquote_splicing(
        for i <- 0..15, do: quote(do: unquote(Enum.at(m, i)) = u32_le(src, off + unquote(4 * i)))
      )

      unquote_splicing(
        for i <- 0..15 do
          val =
            case i do
              i when i < 8 -> Enum.at(c, i)
              12 -> quote(do: band(counter, 0xFFFFFFFF))
              13 -> quote(do: bsr(counter, 32))
              14 -> quote(do: blen)
              15 -> quote(do: flags)
              i -> Enum.at(iv3, i - 8)
            end

          quote(do: unquote(Gen.var(:"v#{i}")) = unquote(val))
        end
      )

      unquote_splicing(Gen.rounds(Gen.schedule3(), &Gen.g3(&1, &2, &3, &4, &5, &6, true)))

      {unquote_splicing(
         for i <- 0..7,
             do: quote(do: bxor(unquote(Gen.var(:"v#{i}")), unquote(Gen.var(:"v#{i + 8}"))))
       )}
    end

    # A parent node: the block is the left CV then the right CV, counter 0
    defk b3_parent(
           unquote_splicing(typed.(Enum.take(l, 8))),
           unquote_splicing(typed.(Enum.take(r, 8))),
           unquote_splicing(typed.(Enum.take(c, 8))),
           flags :: i64
         ) :: unquote(tuple_t.(8)) do
      unquote_splicing(
        for i <- 0..15 do
          src = if i < 8, do: Enum.at(l, i), else: Enum.at(r, i - 8)
          quote(do: unquote(Enum.at(m, i)) = unquote(src))
        end
      )

      unquote_splicing(
        for i <- 0..15 do
          val =
            case i do
              i when i < 8 -> Enum.at(c, i)
              12 -> 0
              13 -> 0
              14 -> 64
              15 -> quote(do: flags)
              i -> Enum.at(iv3, i - 8)
            end

          quote(do: unquote(Gen.var(:"v#{i}")) = unquote(val))
        end
      )

      unquote_splicing(Gen.rounds(Gen.schedule3(), &Gen.g3(&1, &2, &3, &4, &5, &6, true)))

      {unquote_splicing(
         for i <- 0..7,
             do: quote(do: bxor(unquote(Gen.var(:"v#{i}")), unquote(Gen.var(:"v#{i + 8}"))))
       )}
    end
  end

Module.create(Blake.Kernels, kernels, Macro.Env.location(__ENV__))

defmodule Blake.Elixir2b64 do
  @moduledoc """
  Pure Elixir BLAKE2b, first pass: unsigned 64-bit words, the same unrolled
  rounds as the kernel. Every word above 2^59 is a bignum.
  """
  import Bitwise
  alias Blake.Gen

  def hash(msg, outlen \\ 64, key \\ <<>>) do
    kk = byte_size(key)
    [iv0 | ivs] = Gen.iv2b()
    h = List.to_tuple([bxor(iv0, 0x01010000 + 256 * kk + outlen) | ivs])

    h =
      cond do
        kk == 0 -> blocks(msg, h, 0)
        msg == <<>> -> final(pad(key), h, 128)
        true -> blocks(msg, compress(h, pad(key), 128, 0), 128)
      end

    out = for i <- 0..7, into: <<>>, do: <<elem(h, i)::little-64>>
    binary_part(out, 0, outlen)
  end

  def pad(b), do: <<b::binary, 0::size(8 * (128 - byte_size(b)))>>

  defp blocks(<<blk::binary-128, rest::binary>>, h, t) when rest != <<>>,
    do: blocks(rest, compress(h, blk, t + 128, 0), t + 128)

  defp blocks(last, h, t), do: final(pad(last), h, t + byte_size(last))

  defp final(blk, h, t), do: compress(h, blk, t, 0xFFFFFFFFFFFFFFFF)

  def compress(
        {unquote_splicing(Gen.vs("h", 8))},
        <<unquote_splicing(for v <- Gen.vs("m", 16), do: quote(do: unquote(v) :: little - 64))>>,
        t,
        last
      ) do
    unquote_splicing(
      for i <- 0..15 do
        iv = Enum.at(Gen.iv2b(), rem(i, 8))

        val =
          case i do
            i when i < 8 -> Gen.var(:"h#{i}")
            12 -> quote(do: bxor(unquote(iv), unquote(Gen.var(:t))))
            14 -> quote(do: bxor(unquote(iv), unquote(Gen.var(:last))))
            _ -> iv
          end

        quote(do: unquote(Gen.var(:"v#{i}")) = unquote(val))
      end
    )

    unquote_splicing(Gen.rounds(Gen.schedule2b(), &Gen.g2b_elixir64/6))

    {unquote_splicing(
       for i <- 0..7,
           do:
             quote(
               do:
                 bxor(
                   bxor(unquote(Gen.var(:"h#{i}")), unquote(Gen.var(:"v#{i}"))),
                   unquote(Gen.var(:"v#{i + 8}"))
                 )
             )
     )}
  end
end

defmodule Blake.Elixir2b do
  @moduledoc """
  Pure Elixir BLAKE2b, optimised: each 64-bit word as two 32-bit halves
  (vIh, vIl), so nothing allocates a bignum; the rounds unrolled as in the
  kernel; the block's 32 half-words matched in the function head.
  """
  import Bitwise
  alias Blake.Gen

  @ivh Enum.map(Gen.iv2b(), &bsr(&1, 32))
  @ivl Enum.map(Gen.iv2b(), &band(&1, 0xFFFFFFFF))

  def hash(msg, outlen \\ 64, key \\ <<>>) do
    kk = byte_size(key)
    [l0 | ls] = @ivl

    h =
      List.to_tuple(
        Enum.zip_with(@ivh, [bxor(l0, 0x01010000 + 256 * kk + outlen) | ls], &[&1, &2])
        |> List.flatten()
      )

    h =
      cond do
        kk == 0 -> blocks(msg, h, 0)
        msg == <<>> -> compress(h, Blake.Elixir2b64.pad(key), 128, 0xFFFFFFFF)
        true -> blocks(msg, compress(h, Blake.Elixir2b64.pad(key), 128, 0), 128)
      end

    out =
      for i <- 0..7, into: <<>>, do: <<elem(h, 2 * i + 1)::little-32, elem(h, 2 * i)::little-32>>

    binary_part(out, 0, outlen)
  end

  defp blocks(<<blk::binary-128, rest::binary>>, h, t) when rest != <<>>,
    do: blocks(rest, compress(h, blk, t + 128, 0), t + 128)

  defp blocks(last, h, t),
    do: compress(h, Blake.Elixir2b64.pad(last), t + byte_size(last), 0xFFFFFFFF)

  # t is the byte counter (below 2^61); last is 0xFFFFFFFF for the final block
  def compress(
        {unquote_splicing(for i <- 0..7, v <- [Gen.var(:"h#{i}h"), Gen.var(:"h#{i}l")], do: v)},
        <<unquote_splicing(
            for i <- 0..15,
                v <- [Gen.var(:"m#{i}l"), Gen.var(:"m#{i}h")],
                do: quote(do: unquote(v) :: little - 32)
          )>>,
        t,
        last
      ) do
    unquote_splicing(
      for i <- 0..15, half <- ["h", "l"] do
        ivw = Enum.at(Gen.iv2b(), rem(i, 8))
        iv = if half == "h", do: bsr(ivw, 32), else: band(ivw, 0xFFFFFFFF)

        val =
          case {i, half} do
            {i, _} when i < 8 -> Gen.var(:"h#{i}#{half}")
            {12, "l"} -> quote(do: bxor(unquote(iv), band(unquote(Gen.var(:t)), 0xFFFFFFFF)))
            {12, "h"} -> quote(do: bxor(unquote(iv), bsr(unquote(Gen.var(:t)), 32)))
            {14, _} -> quote(do: bxor(unquote(iv), unquote(Gen.var(:last))))
            _ -> iv
          end

        quote(do: unquote(Gen.var(:"v#{i}#{half}")) = unquote(val))
      end
    )

    unquote_splicing(Gen.rounds(Gen.schedule2b(), &Gen.g2b_halves/6))

    {unquote_splicing(
       for i <- 0..7,
           half <- ["h", "l"],
           do:
             quote(
               do:
                 bxor(
                   bxor(unquote(Gen.var(:"h#{i}#{half}")), unquote(Gen.var(:"v#{i}#{half}"))),
                   unquote(Gen.var(:"v#{i + 8}#{half}"))
                 )
             )
     )}
  end
end

defmodule Blake.Elixir3 do
  @moduledoc """
  Pure Elixir BLAKE3, this file's rewrite of b3's loop: the whole message
  in one pass with no structs, full chunks matched 1024 bytes at a time, the
  CV stack a list, the same unrolled rounds as the kernel.
  """
  import Bitwise
  alias Blake.Gen

  @iv List.to_tuple(Gen.iv3())

  def hash(msg), do: chunks(msg, 0, [], @iv, 0)

  def keyed_hash(msg, <<_::binary-32>> = key),
    do: chunks(msg, 0, [], List.to_tuple(for <<w::little-32 <- key>>, do: w), 16)

  defp chunks(<<chunk::binary-1024, rest::binary>>, ci, stack, key, flags) when rest != <<>> do
    cv = chunk_blocks(chunk, key, ci, flags, 1)
    chunks(rest, ci + 1, merge(stack, cv, ci + 1, key, flags), key, flags)
  end

  defp chunks(last, ci, stack, key, flags) do
    root = if stack == [], do: 8, else: 0
    cv = last_blocks(last, key, ci, flags, 1, root)
    out = fold(stack, cv, key, flags)
    for i <- 0..7, into: <<>>, do: <<elem(out, i)::little-32>>
  end

  # full chunk: 16 blocks, CHUNK_START on the first, CHUNK_END on the last
  defp chunk_blocks(<<blk::binary-64>>, cv, ci, flags, start),
    do: block(cv, blk, ci, 64, flags + start + 2)

  defp chunk_blocks(<<blk::binary-64, rest::binary>>, cv, ci, flags, start),
    do: chunk_blocks(rest, block(cv, blk, ci, 64, flags + start), ci, flags, 0)

  defp last_blocks(<<blk::binary-64, rest::binary>>, cv, ci, flags, start, root)
       when rest != <<>>,
       do: last_blocks(rest, block(cv, blk, ci, 64, flags + start), ci, flags, 0, root)

  defp last_blocks(last, cv, ci, flags, start, root) do
    n = byte_size(last)
    block(cv, <<last::binary, 0::size(8 * (64 - n))>>, ci, n, flags + start + 2 + root)
  end

  defp merge([top | rest], cv, total, key, flags) when band(total, 1) == 0,
    do: merge(rest, parent(top, cv, key, flags + 4), bsr(total, 1), key, flags)

  defp merge(stack, cv, _total, _key, _flags), do: [cv | stack]

  defp fold([], cv, _key, _flags), do: cv
  defp fold([top], cv, key, flags), do: parent(top, cv, key, flags + 4 + 8)

  defp fold([top | rest], cv, key, flags),
    do: fold(rest, parent(top, cv, key, flags + 4), key, flags)

  defp parent(
         {unquote_splicing(Gen.vs("m", 8))},
         {unquote_splicing(for i <- 8..15, do: Gen.var(:"m#{i}"))},
         key,
         flags
       ) do
    block(
      key,
      <<unquote_splicing(for v <- Gen.vs("m", 16), do: quote(do: unquote(v) :: little - 32))>>,
      0,
      64,
      flags
    )
  end

  def block(
        {unquote_splicing(Gen.vs("c", 8))},
        <<unquote_splicing(for v <- Gen.vs("m", 16), do: quote(do: unquote(v) :: little - 32))>>,
        counter,
        blen,
        flags
      ) do
    unquote_splicing(
      for i <- 0..15 do
        val =
          case i do
            i when i < 8 -> Gen.var(:"c#{i}")
            12 -> quote(do: band(unquote(Gen.var(:counter)), 0xFFFFFFFF))
            13 -> quote(do: bsr(unquote(Gen.var(:counter)), 32))
            14 -> Gen.var(:blen)
            15 -> Gen.var(:flags)
            i -> Enum.at(Gen.iv3(), i - 8)
          end

        quote(do: unquote(Gen.var(:"v#{i}")) = unquote(val))
      end
    )

    unquote_splicing(Gen.rounds(Gen.schedule3(), &Gen.g3/6))

    {unquote_splicing(
       for i <- 0..7,
           do: quote(do: bxor(unquote(Gen.var(:"v#{i}")), unquote(Gen.var(:"v#{i + 8}"))))
     )}
  end
end

alias Blake.Kernels, as: K
hex = &Base.encode16(&1, case: :lower)
{load, 0} = System.cmd("uptime", [])
IO.puts("load: " <> String.trim(load))

# ---- agreement: BLAKE2b, RFC 7693 ------------------------------------------------
# Appendix A: BLAKE2b-512("abc")
abc512 =
  "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1" <>
    "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"

# Appendix E's self-test: unkeyed and keyed hashes of deterministic inputs at
# 6 lengths and 4 digest lengths, all hashed again with BLAKE2b-256; the
# grand hash is fixed by the RFC.
selftest_seq = fn len, seed ->
  {bytes, _} =
    Enum.map_reduce(1..len//1, {Bitwise.band(0xDEAD4BAD * seed, 0xFFFFFFFF), 1}, fn _, {a, b} ->
      t = Bitwise.band(a + b, 0xFFFFFFFF)
      {Bitwise.bsr(t, 24), {b, t}}
    end)

  :binary.list_to_bin(bytes)
end

rfc_grand = "c23a7800d98123bd10f506c61e29da5603d763b8bbad2e737f5e765a7bccd475"

selftest = fn f ->
  mds =
    for outlen <- [20, 32, 48, 64], inlen <- [0, 3, 128, 129, 255, 1024] do
      input = selftest_seq.(inlen, inlen)
      [f.(input, outlen, <<>>), f.(input, outlen, selftest_seq.(outlen, outlen))]
    end

  hex.(f.(IO.iodata_to_binary(mds), 32, <<>>)) == rfc_grand
end

impls2b = [
  {"kernel", &K.blake2b_keyed(&1, &3, &2)},
  {"Elixir halves", &Blake.Elixir2b.hash/3},
  {"Elixir 64-bit", &Blake.Elixir2b64.hash/3}
]

rfc_ok =
  Enum.all?(impls2b, fn {name, f} ->
    ok = hex.(f.("abc", 64, <<>>)) == abc512 and selftest.(f)
    unless ok, do: IO.puts("RFC 7693 vectors FAILED for #{name}")
    ok
  end) and hex.(K.blake2b("abc", 64)) == abc512

IO.puts("RFC 7693 vectors (abc, Appendix E self-test, keyed and unkeyed): #{rfc_ok}")

# ---- agreement: BLAKE3, the official test vectors --------------------------------
# test_vectors/test_vectors.json of github.com/BLAKE3-team/BLAKE3 (fetched
# 2026-10-11): input i mod 251 for i in 0..len - 1, the first 32 bytes of the
# extended output for hash and keyed_hash (key "whats the Elvish word for friend")
b3_vectors = [
  {0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
   "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"},
  {1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
   "6d7878dfff2f485635d39013278ae14f1454b8c0a3a2d34bc1ab38228a80c95b"},
  {2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63",
   "5392ddae0e0a69d5f40160462cbd9bd889375082ff224ac9c758802b7a6fd20a"},
  {3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f",
   "39e67b76b5a007d4921969779fe666da67b5213b096084ab674742f0d5ec62b9"},
  {4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32",
   "7671dde590c95d5ac9616651ff5aa0a27bee5913a348e053b8aa9108917fe070"},
  {5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2",
   "73ac69eecf286894d8102018a6fc729f4b1f4247d3703f69bdc6a5fe3e0c8461"},
  {6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844",
   "82d3199d0013035682cc7f2a399d4c212544376a839aa863a0f4c91220ca7a6d"},
  {7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe",
   "af0a7ec382aedc0cfd626e49e7628bc7a353a4cb108855541a5651bf64fbb28a"},
  {8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb",
   "be2f5495c61cba1bb348a34948c004045e3bd4dae8f0fe82bf44d0da245a0600"},
  {63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b",
   "bb1eb5d4afa793c1ebdd9fb08def6c36d10096986ae0cfe148cd101170ce37ae"},
  {64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98",
   "ba8ced36f327700d213f120b1a207a3b8c04330528586f414d09f2f7d9ccb7e6"},
  {65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee",
   "c0a4edefa2d2accb9277c371ac12fcdbb52988a86edc54f0716e1591b4326e72"},
  {127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d",
   "c64200ae7dfaf35577ac5a9521c47863fb71514a3bcad18819218b818de85818"},
  {128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef",
   "b04fe15577457267ff3b6f3c947d93be581e7e3a4b018679125eaf86f6a628ec"},
  {129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12",
   "d4a64dae6cdccbac1e5287f54f17c5f985105457c1a2ec1878ebd4b57e20d38f"},
  {1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11",
   "c951ecdf03288d0fcc96ee3413563d8a6d3589547f2c2fb36d9786470f1b9d6e"},
  {1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7",
   "75c46f6f3d9eb4f55ecaaee480db732e6c2105546f1e675003687c31719c7ba4"},
  {1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444",
   "357dc55de0c7e382c900fd6e320acc04146be01db6a8ce7210b7189bd664ea69"},
  {2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a",
   "879cf1fa2ea0e79126cb1063617a05b6ad9d0b696d0d757cf053439f60a99dd1"},
  {2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030",
   "9f29700902f7c86e514ddc4df1e3049f258b2472b6dd5267f61bf13983b78dd5"},
  {3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2",
   "044a0e7b172a312dc02a4c9a818c036ffa2776368d7f528268d2e6b5df191770"},
  {3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3",
   "68dede9bef00ba89e43f31a6825f4cf433389fedae75c04ee9f0cf16a427c95a"},
  {4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969",
   "befc660aea2f1718884cd8deb9902811d332f4fc4a38cf7c7300d597a081bfc0"},
  {4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995",
   "00df940cd36bb9fa7cbbc3556744e0dbc8191401afe70520ba292ee3ca80abbc"},
  {5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833",
   "2c493e48e9b9bf31e0553a22b23503c0a3388f035cece68eb438d22fa1943e20"},
  {5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff",
   "6ccf1c34753e7a044db80798ecd0782a8f76f33563accaddbfbb2e0ea4b2d024"},
  {6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205",
   "3d6b6d21281d0ade5b2b016ae4034c5dec10ca7e475f90f76eac7138e9bc8f1d"},
  {6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f",
   "9ac301e9e39e45e3250a7e3b3df701aa0fb6889fbd80eeecf28dbc6300fbc539"},
  {7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a",
   "b42835e40e9d4a7f42ad8cc04f85a963a76e18198377ed84adddeaecacc6f3fc"},
  {7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817",
   "ed9b1a922c046fdb3d423ae34e143b05ca1bf28b710432857bf738bcedbfa511"},
  {8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63",
   "dc9637c8845a770b4cbf76b8daec0eebf7dc2eac11498517f08d44c8fc00d58a"},
  {8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b",
   "954a2a75420c8d6547e3ba5b98d963e6fa6491addc8c023189cc519821b4a1f5"},
  {16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4",
   "9e9fc4eb7cf081ea7c47d1807790ed211bfec56aa25bb7037784c13c4b707b0d"},
  {31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47",
   "efa53b389ab67c593dba624d898d0f7353ab99e4ac9d42302ee64cbf9939a419"},
  {102_400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085",
   "1c35d1a5811083fd7119f5d5d1ba027b4d01c0c6c49fb6ff2cf75393ea5db4a7"}
]

b3_key = "whats the Elvish word for friend"
b3_input = fn n -> :binary.list_to_bin(for i <- 0..(n - 1)//1, do: rem(i, 251)) end

b3_vectors_ok =
  Enum.all?(b3_vectors, fn {n, want, want_keyed} ->
    msg = b3_input.(n)

    ok =
      Enum.all?([K.blake3(msg), Blake.Elixir3.hash(msg), B3.hash(msg)], &(hex.(&1) == want)) and
        Enum.all?(
          [K.blake3_keyed(msg, b3_key), Blake.Elixir3.keyed_hash(msg, b3_key)],
          &(hex.(&1) == want_keyed)
        )

    unless ok, do: IO.puts("BLAKE3 vector #{n} FAILED")
    ok
  end)

IO.puts(
  "BLAKE3 official vectors (#{length(b3_vectors)} lengths, hash and keyed_hash; kernel, Elixir, b3): #{b3_vectors_ok}"
)

# ---- agreement: random messages against :crypto and the NIFs --------------------
:rand.seed(:exsss, {52, 2, 0})
# every length up to 600 (both hashes' block and padding edges), then longer
# ones up to 20 BLAKE3 chunks (tree merges at every level up to 16 chunks)
lengths = Enum.to_list(0..600) ++ for(_ <- 1..60, do: :rand.uniform(20_480))
random_msgs = for n <- lengths, do: :crypto.strong_rand_bytes(n)

random_ok =
  Enum.all?(random_msgs, fn msg ->
    outlen = :rand.uniform(64)
    key = :crypto.strong_rand_bytes(:rand.uniform(65) - 1)
    b2_nif = Blake2.Blake2b.hash(msg, key, outlen)
    k3 = :crypto.strong_rand_bytes(32)

    K.blake2b(msg, 64) == :crypto.hash(:blake2b, msg) and
      K.blake2b_keyed(msg, key, outlen) == b2_nif and
      Blake.Elixir2b.hash(msg, outlen, key) == b2_nif and
      K.blake3(msg) == Blake3.hash(msg) and Blake.Elixir3.hash(msg) == Blake3.hash(msg) and
      K.blake3_keyed(msg, k3) == Blake3.keyed_hash(k3, msg) and
      Blake.Elixir3.keyed_hash(msg, k3) == Blake3.keyed_hash(k3, msg)
  end) and
    Enum.all?(Enum.take_every(random_msgs, 7), fn msg ->
      Blake.Elixir2b64.hash(msg) == :crypto.hash(:blake2b, msg) and
        HexBlake2.hash2b(msg) == :crypto.hash(:blake2b, msg) and B3.hash(msg) == Blake3.hash(msg)
    end)

IO.puts(
  "#{length(random_msgs)} random messages (0..20480 bytes, random keys and digest lengths): " <>
    "kernels and Elixir equal :crypto, blake2_elixir, blake3 (NIF), blake2 and b3: #{random_ok}"
)

raises? = fn f, mod ->
  try do
    f.()
    false
  rescue
    e -> e.__struct__ == mod
  end
end

bad_ok =
  raises?.(fn -> K.blake2b("abc", 0) end, ArgumentError) and
    raises?.(fn -> K.blake2b("abc", 65) end, ArgumentError) and
    raises?.(fn -> K.blake2b_keyed("abc", :binary.copy(<<1>>, 65), 32) end, ArgumentError) and
    raises?.(fn -> K.blake3_keyed("abc", :binary.copy(<<1>>, 31)) end, ArgumentError)

# ---- agreement: Elixir mode ------------------------------------------------------
# Elixir mode is compiled only under a Mix project in :dev or :test, which a
# Mix.install script does not have: declare a throwaway project and compile
# the same quoted kernels again under :test.
defmodule BlakeExample.MixProject do
  use Mix.Project
  def project, do: [app: :blake_example, version: "0.0.0"]
end

mix_env = Mix.env()
Mix.env(:test)
Module.create(Blake.ElixirMode, kernels, Macro.Env.location(__ENV__))
Mix.env(mix_env)

em = &Blake.ElixirMode.__defk_elixir__/2
mode_msgs = Enum.take_every(random_msgs, 5) ++ Enum.map([0, 1024, 1025, 3073, 8193], b3_input)

mode_ok =
  Enum.all?(mode_msgs, fn msg ->
    key = binary_part(msg <> b3_key, 0, 32)

    em.(:blake2b, [msg, 64]) == K.blake2b(msg, 64) and
      em.(:blake2b_keyed, [msg, key, 20]) == K.blake2b_keyed(msg, key, 20) and
      em.(:blake3, [msg]) == K.blake3(msg) and
      em.(:blake3_keyed, [msg, key]) == K.blake3_keyed(msg, key)
  end) and
    raises?.(fn -> em.(:blake2b, ["abc", 0]) end, ArgumentError) and
    raises?.(fn -> em.(:blake2b_keyed, ["abc", :binary.copy(<<1>>, 65), 32]) end, ArgumentError) and
    raises?.(fn -> em.(:blake3_keyed, ["abc", <<1>>]) end, ArgumentError)

IO.puts(
  "Elixir mode equals the kernels (#{length(mode_msgs)} messages, 4 kernels) and both raise on bad arguments: #{mode_ok and bad_ok}"
)

all_ok = rfc_ok and b3_vectors_ok and random_ok and bad_ok and mode_ok

# ---- timing ----------------------------------------------------------------------
m1k = :crypto.strong_rand_bytes(1024)
m64k = :crypto.strong_rand_bytes(64 * 1024)
m64m = :crypto.strong_rand_bytes(64 * 1024 * 1024)

# interleaved best-of: every round runs each side once, after a full GC
interleaved = fn sides, rounds ->
  Enum.reduce(1..rounds, %{}, fn _, best ->
    Enum.reduce(sides, best, fn {name, f}, best ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      Map.update(best, name, us, &min(&1, us))
    end)
  end)
end

show = fn sides, best, bytes ->
  for {name, _} <- sides do
    us = best[name]

    IO.puts(
      "  #{String.pad_trailing(name, 40)} #{String.pad_leading(Float.to_string(Float.round(us / 1000, 3)), 9)} ms  " <>
        "#{Float.round(bytes / max(us, 1) / 1000, 3)} GB/s"
    )
  end
end

if System.get_env("BLAKE_VARIANTS") do
  sides2b = [
    {"blake2 1.0.4 (pure Elixir, Hex)", fn -> HexBlake2.hash2b(m64k) end},
    {"Elixir, 64-bit words (first pass)", fn -> Blake.Elixir2b64.hash(m64k) end},
    {"Elixir, 32-bit halves", fn -> Blake.Elixir2b.hash(m64k) end},
    {"defk blake2b", fn -> K.blake2b(m64k, 64) end},
    {":crypto.hash(:blake2b, _)", fn -> :crypto.hash(:blake2b, m64k) end},
    {"blake2_elixir 0.9.0 (reference C NIF)", fn -> Blake2.Blake2b.hash(m64k, "", 64) end}
  ]

  IO.puts("\nBLAKE2b-512 variants, 64 KB (best of 5 interleaved rounds):")
  show.(sides2b, interleaved.(sides2b, 5), 64 * 1024)

  sides3 = [
    {"b3 0.2.1 (pure Elixir, Hex)", fn -> B3.hash(m64k) end},
    {"Elixir, this file's loop", fn -> Blake.Elixir3.hash(m64k) end},
    {"defk blake3", fn -> K.blake3(m64k) end},
    {"blake3 1.0.2 (Rust NIF, NEON)", fn -> Blake3.hash(m64k) end}
  ]

  IO.puts("\nBLAKE3 variants, 64 KB (best of 9 interleaved rounds):")
  show.(sides3, interleaved.(sides3, 9), 64 * 1024)
end

big = [
  {"defk blake2b", fn -> K.blake2b(m64m, 64) end},
  {":crypto blake2b", fn -> :crypto.hash(:blake2b, m64m) end},
  {"blake2_elixir (C NIF)", fn -> Blake2.Blake2b.hash(m64m, "", 64) end},
  {"defk blake3", fn -> K.blake3(m64m) end},
  {"blake3 (Rust NIF, NEON)", fn -> Blake3.hash(m64m) end}
]

IO.puts("\n64 MB, native sides (best of 3 interleaved rounds):")
show.(big, interleaved.(big, 3), 64 * 1024 * 1024)
IO.puts("")

e2b = &Blake.Elixir2b.hash/1
e3 = &Blake.Elixir3.hash/1

Defk.Bench.report(
  name: "blake",
  expected: :good,
  baseline: :optimized,
  realistic_size: "one 64 KB message (content hashing, dedup)",
  elixir: fn -> e2b.(m64k) end,
  defk: fn -> K.blake2b(m64k, 64) end,
  native: {fn -> Blake2.Blake2b.hash(m64k, "", 64) end, "blake2_elixir 0.9.0 (reference C)"},
  check: fn -> all_ok and K.blake2b(m64k, 64) == e2b.(m64k) end,
  sweep: [
    {"1 KB", fn -> e2b.(m1k) end, fn -> K.blake2b(m1k, 64) end},
    {"64 KB", fn -> e2b.(m64k) end, fn -> K.blake2b(m64k, 64) end},
    {"64 MB", fn -> e2b.(m64m) end, fn -> K.blake2b(m64m, 64) end}
  ],
  responsiveness: [
    elixir: fn -> e2b.(m64m) end,
    defk: fn -> K.blake2b(m64m, 64) end,
    native: fn -> Blake2.Blake2b.hash(m64m, "", 64) end
  ],
  reason:
    "BLAKE2b-512 from scratch: 12 rounds of 64-bit adds, xors and rotates, where pure Elixir splits every word in two to stay in small integers; level with the reference C NIF and :crypto"
)

# :crypto has BLAKE2b (OpenSSL), so the Elixir answer for BLAKE2b-512 is
# :crypto.hash(:blake2b, msg): the kernel only ties it
crypto_report =
  Defk.Bench.report(
    name: "blake_crypto",
    expected: :marginal,
    baseline: :optimized,
    realistic_size: "one 64 KB message",
    elixir: fn -> :crypto.hash(:blake2b, m64k) end,
    defk: fn -> K.blake2b(m64k, 64) end,
    check: fn -> K.blake2b(m64k, 64) == :crypto.hash(:blake2b, m64k) end,
    sweep: [
      {"1 KB", fn -> :crypto.hash(:blake2b, m1k) end, fn -> K.blake2b(m1k, 64) end},
      {"64 MB", fn -> :crypto.hash(:blake2b, m64m) end, fn -> K.blake2b(m64m, 64) end}
    ],
    reason:
      "BLAKE2b-512 ships in :crypto (OpenSSL's portable C); the kernel is level with it (1.0-1.2x): use :crypto.hash(:blake2b, msg)"
  )

blake3_report =
  Defk.Bench.report(
    name: "blake3",
    expected: :good,
    baseline: :optimized,
    realistic_size: "one 64 KB message (content hashing, dedup)",
    elixir: fn -> e3.(m64k) end,
    defk: fn -> K.blake3(m64k) end,
    native: {fn -> Blake3.hash(m64k) end, "blake3 1.0.2 (Rust blake3 1.3.3, NEON)"},
    check: fn -> all_ok and K.blake3(m64k) == e3.(m64k) end,
    sweep: [
      {"1 KB", fn -> e3.(m1k) end, fn -> K.blake3(m1k) end},
      {"64 KB", fn -> e3.(m64k) end, fn -> K.blake3(m64k) end},
      {"64 MB", fn -> e3.(m64m) end, fn -> K.blake3(m64m) end}
    ],
    responsiveness: [
      elixir: fn -> e3.(m64m) end,
      defk: fn -> K.blake3(m64m) end,
      native: fn -> Blake3.hash(m64m) end
    ],
    reason:
      "BLAKE3's 32-bit words keep pure Elixir in small integers (b3 is already tuned), but the kernel is still ~10x and level with blake3's portable C; the NEON NIF is ~1.6x faster"
  )

# mix defk.examples reads the first DEFK_RESULT line; check the other two here. The
# :crypto line may measure marginal or poor (a tie either way): both mean
# "use :crypto".
unless crypto_report.correct and crypto_report.verdict in [:marginal, :poor] and
         blake3_report.correct and blake3_report.verdict == blake3_report.expected do
  IO.puts("blake_crypto or blake3 failed its check or measured another verdict")
  System.halt(1)
end
