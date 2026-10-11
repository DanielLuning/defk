# argon2: Argon2id (RFC 9106) written from scratch as a kernel, against
# argon2_elixir (the reference C on a dirty scheduler)
#
# GOVERNANCE. This is a password-hashing implementation for measurement, not
# for production. It needs an independent review before any production use:
# the RFC vectors and agreement with the reference C below show it computes
# Argon2, they are not an audit. The kernel is not constant-time and does not
# try to be: Argon2id's first half (pass 0, slices 0 and 1) uses
# data-independent addressing by design, the rest is data-dependent like the
# reference, and the 64 MiB block array is freed without being wiped (the
# reference wipes it). The final comparison of a stored tag must happen in
# Elixir with a constant-time compare, :crypto.hash_equals/2, as `verify`
# below does; never `==` on tags.
#
# Why people reach for a NIF here: Argon2 is memory-hard by design. One hash
# fills 1 MiB to 1 GiB of 1 KiB blocks with a BLAKE2b-based mixing function
# and takes 10-500 ms, so every Elixir library wraps phc-winner-argon2's C:
# argon2_elixir 4.1.3 (comeonin; elixir_make, ref.c without SSE, dirty CPU
# scheduler, `parallelism` lanes on as many pthreads, m_cost given as log2 of
# the KiB). Hex has no pure-BEAM Argon2: antigone (Gleam) depends on
# argon2_elixir, argus and jargon are C NIFs, argon2id_elixir and aragorn2
# Rust NIFs. jargon 1.1.0 was tried as a second oracle and is not one: its
# c_src defines ARGON2_VERSION 13 (decimal, not 0x13), so its tags carry
# version 13 in H_0 ("v=13" in the encoded string), match no other
# implementation and fail here; reported here, not upstream.
#
# Pre-registered verdict (defk-52v.9): marginal on speed, with the tick gap
# and the process kill beside it. Measured: level with the reference C lane
# for lane (0.88-1.05x), but argon2_elixir's default of 4 lanes runs on 4
# threads and the kernel computes lanes one after another, so at the
# defaults the kernel is 0.23-0.29x: poor. The pre-registration held for one
# lane only. This is a comparison with a C NIF on parity and on the runtime
# contract, not a speedup claim: the Elixir answer is argon2_elixir.
#
#   elixir examples/argon2.exs
#
# DEFK_RESULT lines, in this order (run_all.exs reads the first; the script
# checks the second itself and exits 1 when it fails):
#   1. argon2           argon2id at argon2_elixir's defaults (t_cost 3,
#                       64 MiB, 4 lanes, 32-byte tag) vs argon2_elixir: poor
#   2. argon2_one_lane  t_cost 2, 16 MiB, 1 lane (OWASP's minimum is 19 MiB,
#                       2 passes, 1 lane; 16 MiB is the nearest power of two
#                       argon2_elixir takes): a tie, marginal or poor
#
# The kernels: argon2id(password, salt, t_cost, m_cost_kib, parallelism,
# out_len) :: [u8], the ticket's signature, and argon2(pwd, salt, secret, ad,
# t, m, p, tlen, type) for all three types with RFC 9106's optional secret K
# and associated data X (argon2id calls it with empty ones). Version 0x13
# only. The memory is one alloc'd [i64] of 128 * (m' + 3) words: the m'
# blocks, lanes of q = m'/p blocks, then a zero block, the address input
# block Z and the address block, so the one compression kernel works on one
# array. Lanes are computed in sequence, slice by slice as the RFC requires
# (parallelism changes the indexing and the tag, not the speed).
#
#   - fill(mem, r, prev, ref, cur, mask) is G (RFC 9106 3.5): R = X ^ Y into
#     a 128-word scratch r, block cur gets R (^ the old block when mask is
#     -1, passes after the first), then P on r's 8 rows (16 consecutive
#     words) and 8 columns (word pairs 16 apart), then r is XORed into
#     block cur. perm(r, base, s) is one P: 16 loads, BLAKE2b's round with
#     GB's multiplications, wrap64(a + b + 2 * band(a, 0xFFFFFFFF) *
#     band(b, 0xFFFFFFFF)) and rotr64, 16 stores.
#   - segment(...) computes one lane's segment of one slice: for Argon2i and
#     Argon2id's first half, the segment's addresses first (Z with counter
#     k, G(0, G(0, Z)), 128 per block) into an alloc'd [i64]; then each
#     block's reference lane and index (3.4.2) with J_1^2 / 2^32 and
#     |W| * x / 2^32 as mulhi(wrap64(bsl(j1, 32)), j1): exact 64-bit
#     products without leaving i64.
#   - hprime(a, n, tlen) is H' (3.3) and blake2b(msg, n, outlen) BLAKE2b
#     (RFC 7693) on the first n bytes, the round code generated as in
#     examples/blake.exs.
#
# Code size: a kernel call is inlined at each call site (defk-6ag). The
# first draft called BLAKE2b's compression at 2 sites per BLAKE2b and
# BLAKE2b at 3 sites per H', and the generated C was 26.6 MB (clang -O3 had
# not finished after 10 minutes). One call site per helper (every BLAKE2b
# block copied into a padded 128-byte buffer; H' a single loop over V_1 ..
# V_{r+1}) gives 3.6 MB of C, a 1.1 MB .so and about 2.5 minutes of clang
# under load, half of it the second entry kernel (argon2id inlines argon2).
#
# Language notes: write-not-returned (defk-3z5) rejects a helper that writes
# its array parameter and then rebinds and returns it (fill wrote r[k], then
# `r = for ..., reduce: r`). The workaround, at no run-time cost (no copy in
# the C): the first writes go through a reduce loop over the arrays or a
# helper that returns them (address_input). The arrays are never copied on
# the hot path (the fast-path report lists copies only of the 72-byte H'
# input and in the helpers' own entry points); r's indices need no bounds
# check, mem's three per word in fill stay (their offsets come from data).
#
# Agreement, checked on every run: RFC 9106 section 5's vectors for Argon2d,
# Argon2i and Argon2id (32 KiB, 3 passes, 4 lanes, secret and associated
# data); 60 random parameter sets against argon2_elixir (all three types,
# m a power of two from 8 * p KiB to 4 MiB, 1-8 lanes, 1-4 passes, 4-160
# byte tags, 0-64 byte passwords, 8-32 byte salts) and 40 argon2id sets with
# any m up to 3000 KiB (m' rounding) against phc-winner-argon2's own CLI,
# built here from the sources argon2_elixir vendors; the same tags with a
# forced yield at every safepoint; bad parameters (0 lanes, m < 8p, a 3-byte
# tag, t = 0, 2^24 lanes, type 3) raise ArgumentError natively and in Elixir
# mode; Elixir mode equals the kernel on 6 small cases and the three RFC
# vectors (~0.4 s: Elixir mode rebuilds a binary on every array write, so it
# gets small memory sizes only; it is the oracle, not a baseline).
#
# Speed, one hash, best of 5 interleaved rounds (load averages 25-38):
#
#                                       argon2_elixir   defk     defk vs C
#   t=1, 1 MiB, 1 lane                  0.30-0.33 ms    0.33-0.37 ms  0.88-0.95x
#   t=2, 16 MiB, 1 lane                 9.7-13.5 ms     10.1-13.3 ms  0.91-1.05x
#   t=3, 64 MiB, 1 lane                 71-88 ms        75-93 ms      0.92-0.98x
#   t=3, 64 MiB, 4 lanes (default)      19.5-24.4 ms    75-90 ms      0.25-0.29x
#   t=3, 256 MiB, 4 lanes               87-120 ms       340-523 ms    0.23-0.28x
#
# One lane against one lane the kernel is level with the reference C's
# ref.c (about 2.5 GB/s of blocks computed, 3 x 64 MiB in 76 ms); the
# 4-lane gap is argon2_elixir's 4 threads. Splitting lanes across kernel calls in parallel needs memory
# several calls write in disjoint parts between sync points, which value
# semantics does not give (each slice would copy the whole array;
# defk-52v.17). A burst of 24 hashes at the defaults started at
# once (argon2_elixir on 12 dirty schedulers x 4 threads, kernels on 12
# normal schedulers): argon2_elixir 235-285 ms, defk 275-589 ms (1.2-2.1x
# slower, against 3.6-4x for one hash): when every core is busy the lane
# threads buy less, and what is left is noise from the load. Not tried: lazy masking or other changes to GB (the C does the
# same operations), avoiding the zeroing of the alloc'd array (the C does
# not zero it; probably part of the 0.88x at 1 MiB, not profiled).
#
# The runtime contract. Tick gaps (1 ms ticker on one normal scheduler, five
# runs of one hash at the defaults, Defk.Bench.TickGap): idle VM 2.0-2.5 ms (the
# loaded machine's floor), argon2_elixir 2.0-2.1 ms, defk 2.2-2.5 ms (one
# 9.4 ms outlier on the defk side and 8.9 and 5.2 ms ones on the
# argon2_elixir side across runs, under load). A dirty NIF does not hold the normal schedulers, so
# the tick gap does not separate the two; what separates them is the kill.
# Kill mid-hash (t=4, 256 MiB, 1 lane, killed 60 ms in, one dirty CPU
# scheduler online): both processes are down at once (0.0-0.3 ms), but the
# killed argon2_elixir hash keeps running on its dirty scheduler with its
# memory (RSS +135-150 MiB at the kill) until the C returns: a tiny hash
# started right after the kill waited 403-498 ms for that scheduler. The
# kernel's frame goes at the kill: frames_live 1 -> 0 and
# :erlang.memory(:binary) back from +256 MiB to +0 at once, and the probe
# runs in 0.1 ms. (RSS does not fall within seconds on either side; erts'
# binary allocator and macOS malloc keep the pages.)
#
# NUMBERS ARE PROVISIONAL: measured on a loaded machine (other agents'
# builds and benchmarks; 1-minute load averages 14-38 on 12 cores, Apple M4
# Pro), best of interleaved runs.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:argon2_elixir, "~> 4.1"}
])

defmodule Argon2Ex.Gen do
  @moduledoc """
  The constants of BLAKE2b and the generators of the unrolled rounds: BLAKE2b's
  G for the hash H, and Argon2's GB (BLAKE2b's G with the multiplications,
  RFC 9106 3.6) for the permutation P inside the compression function G.
  """

  # RFC 7693 2.6 (the SHA-512 IV) and 2.7 (the message schedule SIGMA)
  @iv [
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
  # the state words of the four column and four diagonal G calls
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

  def iv, do: @iv
  def var(name), do: Macro.var(name, nil)
  def vs(prefix, n), do: for(i <- 0..(n - 1), do: var(:"#{prefix}#{i}"))

  @doc "BLAKE2b's 12 rounds as statements over v0..v15 and the message words m0..m15."
  def blake2b_rounds do
    for row <- @sigma ++ Enum.take(@sigma, 2),
        {{a, b, c, d}, i} <- Enum.with_index(@g),
        stmt <-
          g(
            var(:"v#{a}"),
            var(:"v#{b}"),
            var(:"v#{c}"),
            var(:"v#{d}"),
            var(:"m#{Enum.at(row, 2 * i)}"),
            var(:"m#{Enum.at(row, 2 * i + 1)}")
          ),
        do: stmt
  end

  @doc "One round of P (RFC 9106 3.6): the eight GB calls over v0..v15, no message."
  def p_round do
    for {a, b, c, d} <- @g,
        stmt <- gb(var(:"v#{a}"), var(:"v#{b}"), var(:"v#{c}"), var(:"v#{d}")),
        do: stmt
  end

  # BLAKE2b's G: u64 bit patterns in i64, wrapping adds, rotr64
  defp g(a, b, c, d, x, y) do
    [
      quote(do: unquote(a) = wrap64(unquote(a) + unquote(b) + unquote(x))),
      quote(do: unquote(d) = rotr64(bxor(unquote(d), unquote(a)), 32)),
      quote(do: unquote(c) = wrap64(unquote(c) + unquote(d))),
      quote(do: unquote(b) = rotr64(bxor(unquote(b), unquote(c)), 24)),
      quote(do: unquote(a) = wrap64(unquote(a) + unquote(b) + unquote(y))),
      quote(do: unquote(d) = rotr64(bxor(unquote(d), unquote(a)), 16)),
      quote(do: unquote(c) = wrap64(unquote(c) + unquote(d))),
      quote(do: unquote(b) = rotr64(bxor(unquote(b), unquote(c)), 63))
    ]
  end

  # Argon2's GB: a = a + b + 2 * trunc(a) * trunc(b) mod 2^64, trunc the low
  # 32 bits; the whole sum is masked arithmetic inside wrap64
  defp gb(a, b, c, d) do
    add = fn x, y ->
      quote(
        do:
          unquote(x) =
            wrap64(
              unquote(x) + unquote(y) +
                2 * band(unquote(x), 0xFFFFFFFF) * band(unquote(y), 0xFFFFFFFF)
            )
      )
    end

    [
      add.(a, b),
      quote(do: unquote(d) = rotr64(bxor(unquote(d), unquote(a)), 32)),
      add.(c, d),
      quote(do: unquote(b) = rotr64(bxor(unquote(b), unquote(c)), 24)),
      add.(a, b),
      quote(do: unquote(d) = rotr64(bxor(unquote(d), unquote(a)), 16)),
      add.(c, d),
      quote(do: unquote(b) = rotr64(bxor(unquote(b), unquote(c)), 63))
    ]
  end
end

alias Argon2Ex.Gen

iv = Enum.map(Gen.iv(), &Defk.Bits.wrap64/1)
[h, m] = for p <- ~w(h m)a, do: Gen.vs(p, 16)
typed = fn vars -> Enum.map(vars, &quote(do: unquote(&1) :: i64)) end
tuple8 = {:{}, [], List.duplicate(quote(do: i64), 8)}
h8 = Enum.take(h, 8)

kernels =
  quote do
    use Defk, elixir_mode: true

    @iv for w <- Argon2Ex.Gen.iv(), into: <<>>, do: <<w::little-64>>

    # ---- the API ----

    # Argon2id (RFC 9106) of a password and a salt: t_cost passes over
    # m_cost_kib KiB in `parallelism` lanes, an out_len-byte tag. Lanes are
    # computed one after another in this one call: parallelism changes the
    # indexing, so the tag, not the speed.
    defk argon2id(
           password :: [u8],
           salt :: [u8],
           t_cost :: i64,
           m_cost_kib :: i64,
           parallelism :: i64,
           out_len :: i64
         ) :: [u8] do
      argon2(password, salt, "", "", t_cost, m_cost_kib, parallelism, out_len, 2)
    end

    # Any type (0 Argon2d, 1 Argon2i, 2 Argon2id), version 0x13, with the
    # optional secret K and associated data X of RFC 9106 3.1
    defk argon2(
           pwd :: [u8],
           salt :: [u8],
           secret :: [u8],
           ad :: [u8],
           t :: i64,
           m :: i64,
           p :: i64,
           tlen :: i64,
           y :: i64
         ) :: [u8] do
      if p < 1 or p > 16_777_215, do: raise(ArgumentError, "parallelism must be in 1..2^24-1")

      if tlen < 4 or tlen > 4_294_967_295,
        do: raise(ArgumentError, "out_len must be in 4..2^32-1")

      if m < 8 * p or m > 4_294_967_295,
        do: raise(ArgumentError, "m_cost must be in 8*parallelism..2^32-1 KiB")

      if t < 1 or t > 4_294_967_295, do: raise(ArgumentError, "t_cost must be in 1..2^32-1")
      if y < 0 or y > 2, do: raise(ArgumentError, "type must be 0, 1 or 2")

      if len(pwd) > 4_294_967_295 or len(salt) > 4_294_967_295 or len(secret) > 4_294_967_295 or
           len(ad) > 4_294_967_295,
         do: raise(ArgumentError, "inputs must be at most 2^32-1 bytes")

      # H_0 (RFC 9106 3.2, step 1)
      n0 = 40 + len(pwd) + len(salt) + len(secret) + len(ad)
      b0 = alloc(u8, n0)
      b0 = put32(b0, 0, p)
      b0 = put32(b0, 4, tlen)
      b0 = put32(b0, 8, m)
      b0 = put32(b0, 12, t)
      b0 = put32(b0, 16, 0x13)
      b0 = put32(b0, 20, y)
      {b0, o} = put_field(b0, 24, pwd)
      {b0, o} = put_field(b0, o, salt)
      {b0, o} = put_field(b0, o, secret)
      {b0, _o} = put_field(b0, o, ad)
      h0 = blake2b(b0, n0, 64)

      # m' blocks of 128 words in p lanes of q blocks, 4 slices of sl blocks;
      # then three scratch blocks: zero, the address input, the addresses
      mp = 4 * p * div(m, 4 * p)
      q = div(mp, p)
      sl = div(q, 4)
      mem = alloc(i64, 128 * (mp + 3))

      # B[i][0] and B[i][1] (steps 3 and 4)
      a = alloc(u8, 72)

      for i <- 0..63//1 do
        a[i] = h0[i]
      end

      mem =
        for lane <- 0..(p - 1)//1, j <- 0..1//1, reduce: mem do
          mem ->
            a = put32(a, 64, j)
            a = put32(a, 68, lane)
            b = hprime(a, 72, 1024)
            c = 128 * (lane * q + j)

            for w <- 0..127//1 do
              mem[c + w] = u64_le(b, 8 * w)
            end

            mem
        end

      # the passes (steps 5 and 6), slice by slice, lanes in order
      r = alloc(i64, 128)
      addrs = alloc(i64, sl)

      {mem, _r, _addrs} =
        for pass <- 0..(t - 1)//1,
            slice <- 0..3//1,
            lane <- 0..(p - 1)//1,
            reduce: {mem, r, addrs} do
          {mem, r, addrs} -> segment(mem, r, addrs, pass, slice, lane, p, q, sl, mp, t, y)
        end

      # C, the XOR of the last column (step 7), as bytes, then the tag
      cb = alloc(u8, 1024)

      for w <- 0..127//1 do
        x =
          for lane <- 0..(p - 1)//1, reduce: 0 do
            x -> bxor(x, mem[128 * (lane * q + q - 1) + w])
          end

        for k <- 0..7//1 do
          cb[8 * w + k] = band(bsr(x, 8 * k), 255)
        end
      end

      hprime(cb, 1024, tlen)
    end

    # One segment: lane `lane` of slice `slice` in pass `pass`
    defk segment(
           mem :: [i64],
           r :: [i64],
           addrs :: [i64],
           pass :: i64,
           slice :: i64,
           lane :: i64,
           p :: i64,
           q :: i64,
           sl :: i64,
           mp :: i64,
           t :: i64,
           y :: i64
         ) :: {[i64], [i64], [i64]} do
      # data-independent addressing: Argon2i, and Argon2id in the first half
      # of the first pass (RFC 9106 3.4.1.3)
      dia = y == 1 or (y == 2 and pass == 0 and slice < 2)
      zb = mp
      ib = mp + 1
      ab = mp + 2
      start = if pass == 0 and slice == 0, do: 2, else: 0

      # the addresses of the whole segment, 128 per address block:
      # G(ZERO, G(ZERO, Z || LE64(k) || ZERO)) for k = 1, 2, ... (3.4.1.2)
      mem = address_input(mem, 128 * ib, pass, lane, slice, mp, t, y)
      naddr = if dia, do: div(sl + 127, 128), else: 0

      {mem, r, addrs} =
        for k <- 0..(naddr - 1)//1, reduce: {mem, r, addrs} do
          {mem, r, addrs} ->
            mem[128 * ib + 6] = k + 1
            {mem, r} = fill(mem, r, zb, ib, ab, 0)
            {mem, r} = fill(mem, r, zb, ab, ab, 0)

            for w <- 0..min(127, sl - 128 * k - 1)//1 do
              addrs[128 * k + w] = mem[128 * ab + w]
            end

            {mem, r, addrs}
        end

      # passes after the first XOR the new block into the old one
      mask = if pass == 0, do: 0, else: -1

      {mem, r} =
        for i <- start..(sl - 1)//1, reduce: {mem, r} do
          {mem, r} ->
            cur = lane * q + slice * sl + i
            prev = if slice * sl + i == 0, do: cur + q - 1, else: cur - 1
            pr = if dia, do: addrs[i], else: mem[128 * prev]
            j1 = band(pr, 0xFFFFFFFF)
            j2 = band(bsr(pr, 32), 0xFFFFFFFF)
            rl = if pass == 0 and slice == 0, do: lane, else: rem(j2, p)
            # the reference set W (3.4.2): its size
            first = if i == 0, do: -1, else: 0

            area =
              cond do
                pass == 0 and slice == 0 -> i - 1
                pass == 0 and rl == lane -> slice * sl + i - 1
                pass == 0 -> slice * sl + first
                rl == lane -> q - sl + i - 1
                true -> q - sl + first
              end

            # |W| - 1 - (|W| * (J_1^2 / 2^32)) / 2^32, the products as mulhi
            x = mulhi(wrap64(bsl(j1, 32)), j1)
            rel = area - 1 - mulhi(wrap64(bsl(x, 32)), area)
            sp = if pass != 0 and slice != 3, do: (slice + 1) * sl, else: 0
            ref = rl * q + rem(sp + rel, q)
            fill(mem, r, prev, ref, cur, mask)
        end

      {mem, r, addrs}
    end

    # The compression function G (RFC 9106 3.5) on blocks of `mem`:
    # block cur = G(block prev, block ref), XORed into the old block cur when
    # mask is -1. R = X ^ Y goes to r, and block cur gets R (^ old) at once,
    # so the 8 row and 8 column rounds of P run on r alone; Z ^ R is then
    # the XOR of r into block cur.
    defk fill(mem :: [i64], r :: [i64], prev :: i64, ref :: i64, cur :: i64, mask :: i64) ::
           {[i64], [i64]} do
      pb = 128 * prev
      rb = 128 * ref
      cb = 128 * cur

      {mem, r} =
        for k <- 0..127//1, reduce: {mem, r} do
          {mem, r} ->
            x = bxor(mem[pb + k], mem[rb + k])
            r[k] = x
            mem[cb + k] = bxor(x, band(mem[cb + k], mask))
            {mem, r}
        end

      r =
        for i <- 0..7//1, reduce: r do
          r -> perm(r, 16 * i, 2)
        end

      r =
        for i <- 0..7//1, reduce: r do
          r -> perm(r, 2 * i, 16)
        end

      for k <- 0..127//1 do
        mem[cb + k] = bxor(mem[cb + k], r[k])
      end

      {mem, r}
    end

    # P on 16 words of r: word k at base + s * div(k, 2) + rem(k, 2); a row
    # of R is s = 2 (16 consecutive words), a column s = 16
    defk perm(r :: [i64], base :: i64, s :: i64) :: [i64] do
      unquote_splicing(
        for k <- 0..15 do
          quote(
            do:
              unquote(Gen.var(:"v#{k}")) =
                r[base + s * unquote(div(k, 2)) + unquote(rem(k, 2))]
          )
        end
      )

      unquote_splicing(Gen.p_round())

      unquote_splicing(
        for k <- 0..15 do
          quote(
            do:
              r[base + s * unquote(div(k, 2)) + unquote(rem(k, 2))] =
                unquote(Gen.var(:"v#{k}"))
          )
        end
      )

      r
    end

    # ---- H' and BLAKE2b ----

    # H'^T(A) for the first n bytes of a (RFC 9106 3.3). V_1 is
    # H^64(LE32(T) || A), V_k = H^64(V_{k-1}), and the tag is the first 32
    # bytes of V_1 .. V_r, then V_{r+1} = H^(T - 32r)(V_r) whole; for T <= 64,
    # r = 0 and V_1 = H^T(LE32(T) || A) is the tag. One BLAKE2b call site in
    # one loop keeps the inlined code small: src holds LE32(T) || A, then
    # each V_k in turn.
    defk hprime(a :: [u8], n :: i64, tlen :: i64) :: [u8] do
      src = alloc(u8, max(n + 4, 64))
      src = put32(src, 0, tlen)

      for i <- 0..(n - 1)//1 do
        src[4 + i] = a[i]
      end

      out = alloc(u8, tlen)
      r = if tlen > 64, do: div(tlen + 31, 32) - 2, else: 0

      for k <- 1..(r + 1)//1 do
        sn = if k == 1, do: n + 4, else: 64
        on = if k <= r, do: 64, else: tlen - 32 * r
        v = blake2b(src, sn, on)
        keep = if k <= r, do: 32, else: on

        for i <- 0..(keep - 1)//1 do
          out[32 * (k - 1) + i] = v[i]
        end

        for i <- 0..63//1, k <= r do
          src[i] = v[i]
        end
      end

      out
    end

    # BLAKE2b (RFC 7693), unkeyed, of the first n bytes of msg, outlen 1..64.
    # Every block is copied into a zero-padded 128-byte blk first, so there
    # is one compression call site (Argon2 hashes at most 1 KiB at a time
    # with H, so the copy costs nothing that matters).
    defk blake2b(msg :: [u8], n :: i64, outlen :: i64) :: [u8] do
      nb = max(div(n + 127, 128), 1)
      blk = alloc(u8, 128)

      unquote_splicing(
        for i <- 0..7 do
          init =
            if i == 0,
              do: quote(do: bxor(u64_le(@iv, 0), 0x01010000 + outlen)),
              else: quote(do: u64_le(@iv, unquote(8 * i)))

          quote(do: unquote(Enum.at(h, i)) = unquote(init))
        end
      )

      {unquote_splicing(h8)} =
        for b <- 0..(nb - 1)//1, reduce: {unquote_splicing(h8)} do
          {unquote_splicing(h8)} ->
            s = 128 * b

            for i <- 0..127//1 do
              blk[i] = if s + i < n, do: msg[s + i], else: 0
            end

            last = if b == nb - 1, do: -1, else: 0
            b2b_compress(unquote_splicing(h8), blk, 0, min(s + 128, n), last)
        end

      out = alloc(u8, outlen)

      for i <- 0..(outlen - 1)//1 do
        w =
          case div(i, 8) do
            unquote(
              Enum.flat_map(0..7, fn j ->
                quote(do: (unquote(j) -> unquote(Enum.at(h, j))))
              end)
            )
          end

        out[i] = band(bsr(w, 8 * rem(i, 8)), 255)
      end

      out
    end

    # F (RFC 7693 3.2): the 128-byte block at src[off..], byte counter t,
    # last = -1 for the final block
    defk b2b_compress(
           unquote_splicing(typed.(h8)),
           src :: [u8],
           off :: i64,
           t :: i64,
           last :: i64
         ) :: unquote(tuple8) do
      unquote_splicing(
        for i <- 0..15, do: quote(do: unquote(Enum.at(m, i)) = u64_le(src, off + unquote(8 * i)))
      )

      unquote_splicing(
        for i <- 0..15 do
          val =
            case i do
              i when i < 8 -> Enum.at(h, i)
              12 -> quote(do: bxor(unquote(Enum.at(iv, 4)), t))
              14 -> quote(do: bxor(unquote(Enum.at(iv, 6)), last))
              i -> Enum.at(iv, i - 8)
            end

          quote(do: unquote(Gen.var(:"v#{i}")) = unquote(val))
        end
      )

      unquote_splicing(Gen.blake2b_rounds())

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

    # Z (RFC 9106 3.4.1.2) into the address input block at word o
    defk address_input(
           mem :: [i64],
           o :: i64,
           pass :: i64,
           lane :: i64,
           slice :: i64,
           mp :: i64,
           t :: i64,
           y :: i64
         ) :: [i64] do
      mem[o] = pass
      mem[o + 1] = lane
      mem[o + 2] = slice
      mem[o + 3] = mp
      mem[o + 4] = t
      mem[o + 5] = y
      mem
    end

    # ---- byte helpers ----

    defk put32(b :: [u8], off :: i64, v :: i64) :: [u8] do
      for k <- 0..3//1 do
        b[off + k] = band(bsr(v, 8 * k), 255)
      end

      b
    end

    # LE32(len(f)) || f at b[off..]; gives the offset after it
    defk put_field(b :: [u8], off :: i64, f :: [u8]) :: {[u8], i64} do
      b = put32(b, off, len(f))

      for i <- 0..(len(f) - 1)//1 do
        b[off + 4 + i] = f[i]
      end

      {b, off + 4 + len(f)}
    end
  end

Module.create(Argon2Ex.Kernels, kernels, Macro.Env.location(__ENV__))

alias Argon2Ex.Kernels, as: K
hex = &Base.encode16(&1, case: :lower)
{load, 0} = System.cmd("uptime", [])
IO.puts("load: " <> String.trim(load))

# argon2_elixir 4.1.3: m_cost is log2 of the KiB, and the C runs the lanes on
# `parallelism` threads; raw_hash gives the tag in hex
ae = fn pw, salt, t, k, p, len, y ->
  Argon2.Base.hash_password(pw, salt,
    t_cost: t,
    m_cost: k,
    parallelism: p,
    hashlen: len,
    format: :raw_hash,
    argon2_type: y
  )
  |> Base.decode16!(case: :lower)
end

# The reference C itself, for memory sizes argon2_elixir cannot take (it
# takes log2 of the KiB): phc-winner-argon2's command-line tool, built from
# the sources argon2_elixir vendors. It reads the password from stdin (at
# most 127 bytes) and takes the salt as an argument (printable here).
ref_src = Path.join(Mix.install_project_dir(), "deps/argon2_elixir/argon2")
ref_cli = Path.join(System.tmp_dir!(), "defk_argon2_ref_cli")

{_, 0} =
  System.cmd(
    "cc",
    ["-O3", "-pthread", "-I#{ref_src}/include", "-I#{ref_src}/src", "-o", ref_cli] ++
      for(
        f <- ~w(argon2.c core.c blake2/blake2b.c thread.c encoding.c ref.c run.c),
        do: "#{ref_src}/src/#{f}"
      )
  )

ref = fn pw, salt, t, m, p, len, y ->
  pwf = Path.join(System.tmp_dir!(), "defk_argon2_pw")
  File.write!(pwf, pw)
  flag = Enum.at(["-d", "-i", "-id"], y)
  cmd = "#{ref_cli} #{salt} #{flag} -t #{t} -k #{m} -p #{p} -l #{len} -r < #{pwf}"
  {out, 0} = System.cmd("sh", ["-c", cmd])
  Base.decode16!(String.trim(out), case: :lower)
end

# ---- agreement: RFC 9106 section 5 ----------------------------------------------
# Password 32 x 01, salt 16 x 02, secret 8 x 03, associated data 12 x 04,
# 32 KiB, 3 passes, 4 lanes, 32-byte tag, version 0x13; one vector per type
rfc_args = [
  :binary.copy(<<1>>, 32),
  :binary.copy(<<2>>, 16),
  :binary.copy(<<3>>, 8),
  :binary.copy(<<4>>, 12),
  3,
  32,
  4,
  32
]

rfc_tags = [
  {0, "Argon2d (5.1)", "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"},
  {1, "Argon2i (5.2)", "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"},
  {2, "Argon2id (5.3)", "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"}
]

rfc_ok =
  Enum.all?(rfc_tags, fn {y, name, want} ->
    ok = hex.(apply(K, :argon2, rfc_args ++ [y])) == want
    unless ok, do: IO.puts("RFC 9106 vector #{name} FAILED")
    ok
  end)

IO.puts(
  "RFC 9106 vectors (Argon2d, Argon2i, Argon2id with secret and associated data): #{rfc_ok}"
)

# ---- agreement: argon2_elixir and the reference C on random parameters -----------
:rand.seed(:exsss, {52, 9, 0})
rnd = fn lo, hi -> lo + :rand.uniform(hi - lo + 1) - 1 end

# argon2_elixir: memory a power of two from 8 * parallelism KiB to 4 MiB
cases_ae =
  for _ <- 1..60 do
    p = rnd.(1, 8)
    k = rnd.(max(3, ceil(:math.log2(8 * p))), 12)
    pw = :crypto.strong_rand_bytes(rnd.(0, 64))
    salt = :crypto.strong_rand_bytes(rnd.(8, 32))
    {pw, salt, rnd.(1, 4), k, p, rnd.(4, 160), rnd.(0, 2)}
  end

ae_ok =
  Enum.all?(cases_ae, fn {pw, salt, t, k, p, len, y} = c ->
    ok =
      K.argon2(pw, salt, "", "", t, Bitwise.bsl(1, k), p, len, y) ==
        ae.(pw, salt, t, k, p, len, y)

    unless ok, do: IO.puts("argon2_elixir disagrees: #{inspect(c)}")
    ok
  end)

# the reference C: any memory size from 8 * parallelism KiB (m' rounds it
# down to a multiple of 4 * parallelism), the argon2id entry point
printable = fn n -> for(_ <- 1..n, into: "", do: <<Enum.random(?a..?z)>>) end

cases_ref =
  for _ <- 1..40 do
    p = rnd.(1, 8)
    pw = :crypto.strong_rand_bytes(rnd.(0, 100))
    {pw, printable.(rnd.(8, 32)), rnd.(1, 4), rnd.(8 * p, 3000), p, rnd.(4, 160)}
  end

ref_ok =
  Enum.all?(cases_ref, fn {pw, salt, t, m, p, len} = c ->
    ok = K.argon2id(pw, salt, t, m, p, len) == ref.(pw, salt, t, m, p, len, 2)
    unless ok, do: IO.puts("the reference C disagrees: #{inspect(c)}")
    ok
  end)

IO.puts(
  "random parameters: #{length(cases_ae)} against argon2_elixir (all three types, m a power of two up to 4 MiB, " <>
    "1..8 lanes, 1..4 passes, 4..160-byte tags): #{ae_ok}; #{length(cases_ref)} argon2id against the reference C " <>
    "(any m up to 3000 KiB): #{ref_ok}"
)

# ---- agreement: forced yields, bad arguments and Elixir mode -----------------------
# Every safepoint yields: the tags must not change
K.__defk_force_yields__(true)

yield_ok =
  Enum.all?(Enum.take(cases_ref, 6), fn {pw, salt, t, m, p, len} ->
    K.argon2id(pw, salt, t, m, p, len) == ref.(pw, salt, t, m, p, len, 2)
  end) and hex.(apply(K, :argon2, rfc_args ++ [2])) == elem(Enum.at(rfc_tags, 2), 2)

K.__defk_force_yields__(false)

bad_args = [
  ["pw", "saltsalt", 1, 8, 0, 32],
  ["pw", "saltsalt", 1, 15, 2, 32],
  ["pw", "saltsalt", 1, 8, 1, 3],
  ["pw", "saltsalt", 0, 8, 1, 32],
  ["pw", "saltsalt", 1, 8, 16_777_216, 32]
]

raises? = fn f ->
  try do
    f.()
    false
  rescue
    e in ArgumentError -> is_exception(e)
  end
end

bad_ok =
  Enum.all?(bad_args, fn args ->
    raises?.(fn -> apply(K, :argon2id, args) end) and
      raises?.(fn -> K.__defk_elixir__(:argon2id, args) end)
  end) and raises?.(fn -> K.argon2("pw", "saltsalt", "", "", 1, 8, 1, 32, 3) end)

# Elixir mode rebuilds a binary on every array write, so it gets small
# memory sizes; the RFC vector (32 KiB, 3 passes, 4 lanes) is the largest
em = &K.__defk_elixir__/2

mode_cases =
  [
    {"pw", "saltsalt", 1, 8, 1, 4},
    {"", "saltsalt", 2, 16, 2, 100},
    {"x", "0123456789abcdef", 1, 24, 3, 64}
  ] ++
    for _ <- 1..3,
        do:
          {:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(16), rnd.(1, 2), rnd.(8, 20),
           1, rnd.(4, 80)}

{mode_us, mode_ok} =
  :timer.tc(fn ->
    Enum.all?(mode_cases, fn {pw, salt, t, m, p, len} ->
      em.(:argon2id, [pw, salt, t, m, p, len]) == K.argon2id(pw, salt, t, m, p, len)
    end) and
      Enum.all?(0..2, fn y ->
        em.(:argon2, rfc_args ++ [y]) == apply(K, :argon2, rfc_args ++ [y])
      end)
  end)

IO.puts(
  "forced yields give the same tags: #{yield_ok}; bad parameters raise ArgumentError natively and in Elixir mode: #{bad_ok}; " <>
    "Elixir mode equals the kernel (#{length(mode_cases)} cases + the 3 RFC vectors, #{div(mode_us, 1000)} ms): #{mode_ok}"
)

all_ok = rfc_ok and ae_ok and ref_ok and yield_ok and bad_ok and mode_ok

# The governance note in practice: verify in Elixir with a constant-time
# compare of the stored tag
verify = fn pw, salt, stored ->
  :crypto.hash_equals(K.argon2id(pw, salt, 3, 65_536, 4, 32), stored)
end

stored = ae.("hunter2", "per-user-salt-16", 3, 16, 4, 32, 2)

IO.puts(
  "verify against an argon2_elixir tag with :crypto.hash_equals/2: #{verify.("hunter2", "per-user-salt-16", stored)} / wrong password #{verify.("hunter3", "per-user-salt-16", stored)}"
)

pw = "correct horse battery staple"
salt = "0123456789abcdef"

# ---- kill mid-hash ----------------------------------------------------------------
# One 256 MiB hash (4 passes, 1 lane) in a process killed 60 ms in, before
# any other large hash has run in this VM. The kernel yields every ~250 us,
# so the kill takes effect at once and the frame's destructor frees the
# 256 MiB array (a binary, so :erlang.memory(:binary) shows it). A dirty NIF
# cannot be interrupted: the process is gone at once, but the C runs to the
# end on its dirty scheduler and frees its malloc'd memory then. The probe:
# with one dirty CPU scheduler online, a tiny argon2_elixir hash started
# right after the kill waits for the killed hash to finish. RSS shows the
# memory in use 60 ms in; it does not fall back within seconds on either
# side (erts' binary allocator and macOS malloc keep the pages), so the
# measures of release are frames_live, :erlang.memory(:binary) and the probe.
rss = fn ->
  {s, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
  String.to_integer(String.trim(s)) * 1024
end

mono = fn -> System.monotonic_time(:microsecond) end
mib = &div(&1, 1024 * 1024)
ms_since = fn t0 -> Float.round((mono.() - t0) / 1000, 1) end

tiny = fn -> ae.("x", "saltsalt", 1, 3, 1, 4, 2) end

kill_run = fn name, f ->
  :erlang.garbage_collect()
  Process.sleep(100)
  rss0 = rss.()
  bin0 = :erlang.memory(:binary)
  {pid, ref} = spawn_monitor(f)
  Process.sleep(60)
  live = K.__defk_stats__().frames_live
  rss1 = rss.()
  bin1 = :erlang.memory(:binary)
  t0 = mono.()
  Process.exit(pid, :kill)

  receive do
    {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
  end

  down_ms = ms_since.(t0)
  probe_ms = elem(:timer.tc(tiny), 0) / 1000
  bin2 = :erlang.memory(:binary)
  live2 = K.__defk_stats__().frames_live

  IO.puts(
    "  #{String.pad_trailing(name, 14)} 60 ms in: RSS +#{mib.(rss1 - rss0)} MiB, binaries +#{mib.(bin1 - bin0)} MiB, " <>
      "frames_live #{live}. After the kill: process down in #{down_ms} ms, a 1-dirty-scheduler probe hash " <>
      "#{Float.round(probe_ms, 1)} ms, " <>
      "binaries +#{mib.(bin2 - bin0)} MiB, frames_live #{live2}"
  )

  %{live: live, after: live2, down_ms: down_ms, probe_ms: probe_ms, bin_left: bin2 - bin0}
end

dirty_online = :erlang.system_info(:dirty_cpu_schedulers_online)
:erlang.system_flag(:dirty_cpu_schedulers_online, 1)

IO.puts(
  "\nKill mid-hash (t=4, 256 MiB, 1 lane; killed 60 ms in; one dirty CPU scheduler online):"
)

kill_ae = kill_run.("argon2_elixir", fn -> ae.(pw, salt, 4, 18, 1, 32, 2) end)
kill_k = kill_run.("defk", fn -> K.argon2id(pw, salt, 4, 262_144, 1, 32) end)
:erlang.system_flag(:dirty_cpu_schedulers_online, dirty_online)

kill_ok =
  kill_k.live == 1 and kill_k.after == 0 and kill_k.bin_left < 16 * 1024 * 1024 and
    kill_ae.after == 0

IO.puts("kernel frame freed on kill (frames_live 1 -> 0, binaries back): #{kill_ok}")

# ---- timing ----------------------------------------------------------------------
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

configs = [
  {"t=1, 1 MiB, 1 lane", 1, 10, 1},
  {"t=2, 16 MiB, 1 lane (OWASP's 19 MiB, rounded)", 2, 14, 1},
  {"t=3, 64 MiB, 1 lane", 3, 16, 1},
  {"t=3, 64 MiB, 4 lanes (argon2_elixir default)", 3, 16, 4},
  {"t=3, 256 MiB, 4 lanes", 3, 18, 4}
]

IO.puts("\nOne hash, best of 5 interleaved rounds (argon2_elixir runs 4 lanes on 4 threads):")

for {label, t, k, p} <- configs do
  sides = [
    {"argon2_elixir", fn -> ae.(pw, salt, t, k, p, 32, 2) end},
    {"defk", fn -> K.argon2id(pw, salt, t, Bitwise.bsl(1, k), p, 32) end}
  ]

  best = interleaved.(sides, 5)
  ms = fn name -> Float.round(best[name] / 1000, 2) end

  IO.puts(
    "  #{String.pad_trailing(label, 48)} argon2_elixir #{ms.("argon2_elixir")} ms, defk #{ms.("defk")} ms " <>
      "(#{Float.round(best["argon2_elixir"] / best["defk"], 2)}x)"
  )
end

# A burst of logins: 24 hashes at argon2_elixir's defaults, all started at
# once. argon2_elixir runs each on a dirty CPU scheduler (12 here) with 4
# threads; the kernels run on the 12 normal schedulers, lanes in sequence.
burst = fn f ->
  {us, _} =
    :timer.tc(fn ->
      1..24 |> Enum.map(fn _ -> Task.async(f) end) |> Task.await_many(:infinity)
    end)

  us
end

burst_best =
  interleaved.(
    [
      {"argon2_elixir", fn -> burst.(fn -> ae.(pw, salt, 3, 16, 4, 32, 2) end) end},
      {"defk", fn -> burst.(fn -> K.argon2id(pw, salt, 3, 65_536, 4, 32) end) end}
    ],
    3
  )

IO.puts(
  "\n24 concurrent hashes at the defaults (t=3, 64 MiB, 4 lanes), best of 3: argon2_elixir " <>
    "#{div(burst_best["argon2_elixir"], 1000)} ms, defk #{div(burst_best["defk"], 1000)} ms"
)

# Tick gaps: a 1 ms ticker on one normal scheduler while one hash runs
# (Defk.Bench.TickGap, the bench/tick_gap.exs method), five runs per side.
# argon2_elixir runs on a dirty scheduler and its own threads, so it never
# holds the ticker's scheduler; the kernel shares it and yields every ~250 us.
# Both are at the loaded machine's floor; the ticker beside an idle VM gives it.
gaps = fn f -> for(_ <- 1..5, do: Defk.Bench.TickGap.run(f)) end
fmt = fn gs -> Enum.map_join(gs, " ", &"#{&1.max}/#{&1.p99}") end
default_ae = fn -> ae.(pw, salt, 3, 16, 4, 32, 2) end
default_k = fn -> K.argon2id(pw, salt, 3, 65_536, 4, 32) end
idle_gaps = gaps.(fn -> Process.sleep(80) end)
ae_gaps = gaps.(default_ae)
k_gaps = gaps.(default_k)

IO.puts(
  "\nTick gaps, max/p99 ms over 5 runs of one hash at the defaults: idle (sleep 80 ms) #{fmt.(idle_gaps)}; " <>
    "argon2_elixir #{fmt.(ae_gaps)}; defk #{fmt.(k_gaps)}"
)

IO.puts("")

# ---- reports ----------------------------------------------------------------------
Defk.Bench.report(
  name: "argon2",
  expected: :poor,
  baseline: :optimized,
  realistic_size: "argon2_elixir's defaults: t_cost 3, m_cost 64 MiB, parallelism 4, 32-byte tag",
  elixir: default_ae,
  defk: default_k,
  check: fn -> all_ok and kill_ok and default_k.() == default_ae.() end,
  sweep: [
    {"t=1, 1 MiB, p=1", fn -> ae.(pw, salt, 1, 10, 1, 32, 2) end,
     fn -> K.argon2id(pw, salt, 1, 1024, 1, 32) end},
    {"t=2, 16 MiB, p=1", fn -> ae.(pw, salt, 2, 14, 1, 32, 2) end,
     fn -> K.argon2id(pw, salt, 2, 16_384, 1, 32) end},
    {"t=3, 64 MiB, p=1", fn -> ae.(pw, salt, 3, 16, 1, 32, 2) end,
     fn -> K.argon2id(pw, salt, 3, 65_536, 1, 32) end},
    {"t=3, 64 MiB, p=4", default_ae, default_k},
    {"t=3, 256 MiB, p=4", fn -> ae.(pw, salt, 3, 18, 4, 32, 2) end,
     fn -> K.argon2id(pw, salt, 3, 262_144, 4, 32) end}
  ],
  responsiveness: [
    elixir: fn -> ae.(pw, salt, 3, 18, 4, 32, 2) end,
    defk: fn -> K.argon2id(pw, salt, 3, 262_144, 4, 32) end
  ],
  reason:
    "argon2id from scratch is level with the reference C lane for lane, but argon2_elixir runs its 4 lanes on 4 threads and the kernel runs them in sequence; use argon2_elixir. The kernel's case is the runtime contract (yields, frees 64 MiB on kill), not speed"
)

# One lane, OWASP's minimum (19 MiB, 2 passes, 1 lane; 16 MiB here, the
# nearest power of two argon2_elixir takes): no threads on either side
one_lane =
  Defk.Bench.report(
    name: "argon2_one_lane",
    expected: :marginal,
    baseline: :optimized,
    realistic_size: "t_cost 2, m_cost 16 MiB, parallelism 1 (OWASP's minimum, rounded)",
    elixir: fn -> ae.(pw, salt, 2, 14, 1, 32, 2) end,
    defk: fn -> K.argon2id(pw, salt, 2, 16_384, 1, 32) end,
    check: fn ->
      all_ok and K.argon2id(pw, salt, 2, 16_384, 1, 32) == ae.(pw, salt, 2, 14, 1, 32, 2)
    end,
    reason:
      "one lane on each side: the kernel ties the reference C (0.9-1.1x), so marginal or poor both mean use argon2_elixir"
  )

# run_all.exs reads the first DEFK_RESULT line; check the second here. A tie
# measures marginal or poor: both mean "use argon2_elixir".
unless one_lane.correct and one_lane.verdict in [:marginal, :poor] do
  IO.puts("argon2_one_lane failed its check or measured another verdict")
  System.halt(1)
end
