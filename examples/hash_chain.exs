# hash_chain: SHA-256 hash chains and HMAC-SHA256 rounds (provably-fair RNG) vs :crypto
#
# The job: provably-fair iGaming RNG derives each round from a hash chain (a
# server seed hashed N times, revealed from the end) or from
# HMAC-SHA256(server_seed, client_seed <> ":" <> nonce), then bytes -> float
# -> outcome. Verifying a player's history recomputes millions of rounds, and
# people ask whether native code would make it faster. Ticket defk-9p6.18;
# pre-registered as marginal or poor: the entry exists to say "use :crypto"
# with numbers.
#
#   elixir examples/hash_chain.exs
#
# Two DEFK_RESULT lines, in this order (mix defk.examples reads the first; the
# script exits 1 itself if either is incorrect or misses its verdict):
#   1. hash_chain   10M-step SHA-256 chain from a 32-byte seed, expected poor
#   2. hmac_rounds  HMAC-SHA256 of 1M nonces under one key, expected marginal
#
# Measured (M-series Mac, OTP 29, Elixir 1.20, a machine shared with other
# jobs, load 13-36; three runs):
#   hash_chain, 10M steps: Elixir 1.01-1.02 s (100-104 ns/step), defk
#     1.75-1.78 s (175-178 ns/step): 0.57-0.58x, poor. Sweep 1k / 100k / 1M /
#     10M steps: 0.55-0.61x / 0.56-0.61x / 0.58-0.64x / 0.57-0.59x, no
#     crossover. The ratio is flat because both sides are per-step costs.
#   hmac_rounds, 1M nonces: Elixir 539-615 ms, defk 414-418 ms: 1.3-1.47x,
#     marginal. Sweep 1 / 100 / 10k / 1M nonces: 0.5x / 0.86-0.91x / 1.1-1.2x
#     / 1.33-1.47x. Against :crypto.mac per round (1.03-1.09 us) the kernel
#     would be 2.5x, which is why the baseline matters (below).
#
# Why: :crypto.hash/2 is OpenSSL, whose SHA-256 block function is assembly
# chosen at run time for the CPU: OpenSSL's crypto/sha/asm/sha512-armv8.pl
# and sha512-x86_64.pl generate the sha256 block functions, with a path on
# the ARMv8 SHA-256 instructions (SHA256H/SHA256H2, picked through
# OPENSSL_armcap_P) and one on x86 SHA-NI (sha256rnds2). A kernel is portable
# C with no intrinsics, so one compression costs about 170 ns here (64
# rounds of 32-bit adds, rotates and xors), more than :crypto's whole step
# with the NIF call and the result binary. The only cost a kernel removes is
# that per-call overhead between steps, and it is smaller than the hardware
# advantage. HMAC narrows the gap only because the kernel compresses the key
# pads once per call (two compressions per round) where Elixir's best does
# four, and saves two calls and the message building per round. Unless defk
# gets an intrinsics path, the answer is :crypto.
#
# Outcome derivation (bytes -> float -> table lookup) is a few operations per
# round (`<<x::32, _::binary>> = digest`, `x / 4_294_967_296`, an index into
# a tuple) and belongs in Elixir next to the :crypto call; no kernel needed.
#
# Compliance: in a regulated game the RNG and its seed chain are part of the
# certified system, so a hand-written SHA-256 replacing OpenSSL is a change
# for the test lab, whatever its speed; and the server seed is a secret until
# it is revealed, which puts the chain under examples/README.md's "secret-
# dependent crypto" row (no constant-time guarantee, and a yielded kernel's
# frame holds the seed). Verifying an already revealed seed is public-input
# work and allowed, but per the numbers above gains nothing. Use :crypto.
#
# Elixir baselines (:optimized; :crypto is the baseline by definition, every
# variant is timed in the run and the fastest is used):
#   chain: Enum.reduce over :crypto.hash/2 (98-113 ns/step), a tail-recursive
#     loop (98-136 ns/step, the baseline; the two are within noise), and
#     :crypto.hash_init once with hash_update + hash_final per step (348-390
#     ns/step: each update copies the context).
#   hmac: :crypto.mac per round (1.03-1.09 us; its per-call key setup
#     dominates), mac_init/update/final (the same), two hash contexts with
#     the padded key absorbed once (0.90-0.99 us, the context copies again),
#     and RFC 2104 by hand with two :crypto.hash calls over the padded key
#     (the baseline: 0.47-0.70 us, four hardware compressions per round). The
#     message is client <> ":" <> Integer.to_string(nonce) in each, and the
#     digests are packed into one binary as the kernel returns them.
#   Not tried: a pure-Elixir SHA-256 (it can only be slower than OpenSSL).
#
# Kernels: sha256(msg) pads any message into one alloc'd copy and compresses
# each 64-byte block (multi-block, all padding cases). sha256_chain(seed, n)
# hashes the seed (any length) once, then n - 1 more times; a 32-byte digest
# is one block whose words 8..15 are constants, so the eight digest words go
# straight into the schedule with no byte buffer in between; n <= 0 returns
# the seed, as Enum.reduce(1..n//1, ...) does. sha256_chain_unrolled is the
# same with the 64 rounds and the schedule unrolled (the timed one: 173-186
# ns/step against 190-211 with the rounds as loops). hmac_sha256_rounds(key,
# client, first, n) compresses the two key pads once, then per nonce writes
# the decimal digits into a reused message buffer and runs the inner blocks
# and one outer block. The compression is written once, as quoted AST in
# HashChain.Source, and spliced into each kernel: a kernel returning eight
# words (a tuple) cannot be called from another kernel. 32-bit rotates are
# `band(bsr(x, n) + bsl(x, 32 - n), 0xFFFFFFFF)` with literal n, so the bsl
# is wrapped masked arithmetic; a rotr32(x, n) kernel taking n as a parameter
# compiled to a checked bsl, and with t1 left unmasked (checked adds) the
# first version took 236 ns/step. Round constants: a 256-byte attribute read
# with u32_be (into an [i64] per call for the loop version, literals in the
# unrolled one).
#
# Agreement: the FIPS 180-4 vectors (empty, "abc", the 56- and 112-byte
# messages) on the kernel, :crypto and Elixir mode; 431 random messages of
# 0..300 bytes (every length 0..130, so every padding boundary) against
# :crypto and, up to 70 bytes, Elixir mode; chains for n = -1..3 and 1000 from
# four seeds (32, 0, 11 and 100 bytes) against all three Elixir chains and
# Elixir mode; the 1M- and 10M-step digests in check:; HMAC rounds for keys
# of 0, 32, 64, 65 and 100 bytes, clients from 0 to 70 bytes (one and two
# inner blocks), nonces across digit-count boundaries and near the i64 limit,
# against :crypto.mac, both Elixir HMACs and Elixir mode.
#
# Realistic sizes: a 10M-step chain (about 1 s for Elixir, so the verdict is
# measured there), 1M HMAC nonces (a long player history).

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule HashChain.Source do
  # The 64 SHA-256 round constants (FIPS 180-4 4.2.2), packed big-endian into
  # a 256-byte attribute that the kernels read with u32_be(@k, 4 * t).
  @k [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2
  ]
  def k_bin, do: for(x <- @k, into: <<>>, do: <<x::32>>)

  # 32-bit rotate right of x (below 2^32) by a literal n, spelled out at the
  # call site: `bsr(x, n) + bsl(x, 32 - n)` under a 32-bit mask. The two
  # parts have no bits in common, so + is the bor, and a bsl by a literal
  # inside the mask is wrapped arithmetic, with no overflow check (a rotr32
  # kernel taking n as a parameter compiles to a checked bsl).
  def rotr(x, n) do
    quote do: band(bsr(unquote(x), unquote(n)) + bsl(unquote(x), unquote(32 - n)), 0xFFFFFFFF)
  end

  def xor3(a, b, c), do: quote(do: bxor(bxor(unquote(a), unquote(b)), unquote(c)))

  # The compression function, shared by both kernels: it is spliced into each
  # kernel body (a kernel cannot pass eight words back to another kernel, since
  # a kernel returning a tuple is not callable from a kernel). In scope: the
  # schedule `w` (an alloc'd [i64] of 64 with w[0..15] loaded), the round
  # constants `k` (an [i64] of 64) and the state words s0..s7; its value is
  # the next state as a tuple.
  def compress do
    x = quote(do: x)
    y = quote(do: y)
    a = quote(do: a)
    e = quote(do: e)

    quote do
      for t <- 16..63//1 do
        x = w[t - 15]
        y = w[t - 2]

        w[t] =
          band(
            w[t - 16] + unquote(xor3(rotr(x, 7), rotr(x, 18), quote(do: bsr(x, 3)))) + w[t - 7] +
              unquote(xor3(rotr(y, 17), rotr(y, 19), quote(do: bsr(y, 10)))),
            0xFFFFFFFF
          )
      end

      {a, b, c, d, e, f, g, h} =
        for t <- 0..63//1, reduce: {s0, s1, s2, s3, s4, s5, s6, s7} do
          {a, b, c, d, e, f, g, h} ->
            t1 =
              band(
                h + unquote(xor3(rotr(e, 6), rotr(e, 11), rotr(e, 25))) +
                  bxor(band(e, f), band(bnot(e), g)) + k[t] + w[t],
                0xFFFFFFFF
              )

            {band(
               t1 + unquote(xor3(rotr(a, 2), rotr(a, 13), rotr(a, 22))) +
                 bxor(bxor(band(a, b), band(a, c)), band(b, c)),
               0xFFFFFFFF
             ), a, b, c, band(d + t1, 0xFFFFFFFF), e, f, g}
        end

      {band(s0 + a, 0xFFFFFFFF), band(s1 + b, 0xFFFFFFFF), band(s2 + c, 0xFFFFFFFF),
       band(s3 + d, 0xFFFFFFFF), band(s4 + e, 0xFFFFFFFF), band(s5 + f, 0xFFFFFFFF),
       band(s6 + g, 0xFFFFFFFF), band(s7 + h, 0xFFFFFFFF)}
    end
  end

  # The same compression fully unrolled, as hand-written C SHA-256 is: the
  # schedule words and the eight state words are fresh variables per round
  # (the rotation of a..h is a renaming, not a move), and the round constants
  # are literals. `words` are 16 expressions for W0..W15, `state` 8 for the
  # incoming state; the result is {statements, the 8 next-state expressions}.
  def compress_unrolled(words, state) do
    v = fn name -> Macro.var(name, __MODULE__) end
    m = 0xFFFFFFFF

    ws = Map.new(Enum.with_index(words), fn {wd, i} -> {i, wd} end)

    # W0..W15 bound once to variables, so each expression is evaluated once
    {w0stmts, ws} =
      Enum.reduce(0..15, {[], ws}, fn i, {acc, ws} ->
        wi = v.(:"w#{i}")
        {[quote(do: unquote(wi) = unquote(ws[i])) | acc], Map.put(ws, i, wi)}
      end)

    {wstmts, ws} =
      Enum.reduce(16..63, {[], ws}, fn t, {acc, ws} ->
        x = ws[t - 15]
        y = ws[t - 2]
        wt = v.(:"w#{t}")

        stmt =
          quote do
            unquote(wt) =
              band(
                unquote(ws[t - 16]) +
                  unquote(xor3(rotr(x, 7), rotr(x, 18), quote(do: bsr(unquote(x), 3)))) +
                  unquote(ws[t - 7]) +
                  unquote(xor3(rotr(y, 17), rotr(y, 19), quote(do: bsr(unquote(y), 10)))),
                unquote(m)
              )
          end

        {[stmt | acc], Map.put(ws, t, wt)}
      end)

    st0 = Enum.with_index(state, fn s, i -> {v.(:"st#{i}"), s} end)
    init = for {var, s} <- st0, do: quote(do: unquote(var) = unquote(s))
    vars0 = Enum.map(st0, &elem(&1, 0))

    {rstmts, [a, b, c, d, e, f, g, h]} =
      Enum.reduce(0..63, {[], vars0}, fn t, {acc, [a, b, c, d, e, f, g, h]} ->
        t1 = v.(:"t1_#{t}")
        na = v.(:"a#{t}")
        ne = v.(:"e#{t}")

        stmts = [
          quote do
            unquote(t1) =
              band(
                unquote(h) + unquote(xor3(rotr(e, 6), rotr(e, 11), rotr(e, 25))) +
                  bxor(band(unquote(e), unquote(f)), band(bnot(unquote(e)), unquote(g))) +
                  unquote(Enum.at(@k, t)) + unquote(ws[t]),
                unquote(m)
              )
          end,
          quote do
            unquote(ne) = band(unquote(d) + unquote(t1), unquote(m))
          end,
          quote do
            unquote(na) =
              band(
                unquote(t1) + unquote(xor3(rotr(a, 2), rotr(a, 13), rotr(a, 22))) +
                  bxor(
                    bxor(band(unquote(a), unquote(b)), band(unquote(a), unquote(c))),
                    band(unquote(b), unquote(c))
                  ),
                unquote(m)
              )
          end
        ]

        {Enum.reverse(stmts) ++ acc, [na, a, b, c, ne, e, f, g]}
      end)

    out =
      Enum.zip(vars0, [a, b, c, d, e, f, g, h])
      |> Enum.map(fn {s, x} -> quote(do: band(unquote(s) + unquote(x), unquote(m))) end)

    {init ++ Enum.reverse(w0stmts) ++ Enum.reverse(wstmts) ++ Enum.reverse(rstmts), out}
  end

  # the round constants as an [i64], built once per call from the attribute
  # (statements, spliced with unquote_splicing: a spliced block would scope k)
  def load_k do
    [
      quote(do: k = alloc(i64, 64)),
      quote do
        for t <- 0..63//1 do
          k[t] = u32_be(@k, 4 * t)
        end
      end
    ]
  end

  defmacro __using__(_) do
    k = k_bin()
    v = fn name -> Macro.var(name, __MODULE__) end

    iv = [
      0x6A09E667,
      0xBB67AE85,
      0x3C6EF372,
      0xA54FF53A,
      0x510E527F,
      0x9B05688C,
      0x1F83D9AB,
      0x5BE0CD19
    ]

    vars = fn prefix -> Enum.map(0..7, &v.(:"#{prefix}#{&1}")) end
    chain_step = compress_unrolled(vars.("d") ++ [0x80000000, 0, 0, 0, 0, 0, 0, 256], iv)

    load = fn arr, base ->
      for i <- 0..15, do: quote(do: u32_be(unquote(arr), unquote(base) + unquote(4 * i)))
    end

    ipad_step = compress_unrolled(load.(v.(:ipad), 0), iv)
    opad_step = compress_unrolled(load.(v.(:opad), 0), iv)
    inner_step = compress_unrolled(load.(v.(:mbuf), quote(do: blk * 64)), vars.("c"))
    # the outer block: the inner digest, 0x80, zeros, (64 + 32) * 8 bits
    outer_step = compress_unrolled(vars.("h") ++ [0x80000000, 0, 0, 0, 0, 0, 0, 768], vars.("o"))

    # the 32 digest bytes of d0..d7 written at out[o + ...]
    store =
      for j <- 0..31 do
        d = v.(:"d#{div(j, 4)}")
        quote(do: out[o + unquote(j)] = band(bsr(unquote(d), unquote(24 - 8 * rem(j, 4))), 255))
      end

    quote do
      @k unquote(k)

      # SHA-256 of a message of any length: padded into one alloc'd copy
      # (0x80, zeros, the bit length big-endian), then one compression per
      # 64-byte block.
      defk sha256(msg :: [u8]) :: [u8] do
        l = len(msg)
        nb = div(l + 8, 64) + 1
        p = alloc(u8, nb * 64)

        for i <- 0..(l - 1)//1 do
          p[i] = msg[i]
        end

        p[l] = 128

        for j <- 0..7//1 do
          p[nb * 64 - 1 - j] = band(bsr(l * 8, 8 * j), 255)
        end

        w = alloc(i64, 64)
        unquote_splicing(load_k())

        {s0, s1, s2, s3, s4, s5, s6, s7} =
          for blk <- 0..(nb - 1)//1,
              reduce:
                {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C,
                 0x1F83D9AB, 0x5BE0CD19} do
            {s0, s1, s2, s3, s4, s5, s6, s7} ->
              for t <- 0..15//1 do
                w[t] = u32_be(p, blk * 64 + 4 * t)
              end

              unquote(compress())
          end

        w[0] = s0
        w[1] = s1
        w[2] = s2
        w[3] = s3
        w[4] = s4
        w[5] = s5
        w[6] = s6
        w[7] = s7
        out = alloc(u8, 32)

        for i <- 0..31//1 do
          out[i] = band(bsr(w[div(i, 4)], 24 - 8 * rem(i, 4)), 255)
        end

        out
      end

      # SHA-256 applied n times: the seed (any length) is hashed once, then
      # each further step hashes the previous 32-byte digest from the initial
      # state; that message is one padded block whose words 8..15 never change
      # (0x80000000, zeros, 256 bits), so the digest's eight words go straight
      # into the schedule.
      # n <= 0 returns the seed, as Enum.reduce(1..n//1, seed, ...) does.
      defk sha256_chain(seed :: [u8], n :: i64) :: [u8] do
        first = sha256(seed)
        out = alloc(u8, if(n <= 0, do: len(seed), else: 32))
        w = alloc(i64, 64)
        unquote_splicing(load_k())
        w[8] = 0x80000000
        w[15] = 256

        {s0, s1, s2, s3, s4, s5, s6, s7} =
          for _step <- 2..n//1,
              reduce:
                {u32_be(first, 0), u32_be(first, 4), u32_be(first, 8), u32_be(first, 12),
                 u32_be(first, 16), u32_be(first, 20), u32_be(first, 24), u32_be(first, 28)} do
            {d0, d1, d2, d3, d4, d5, d6, d7} ->
              w[0] = d0
              w[1] = d1
              w[2] = d2
              w[3] = d3
              w[4] = d4
              w[5] = d5
              w[6] = d6
              w[7] = d7
              s0 = 0x6A09E667
              s1 = 0xBB67AE85
              s2 = 0x3C6EF372
              s3 = 0xA54FF53A
              s4 = 0x510E527F
              s5 = 0x9B05688C
              s6 = 0x1F83D9AB
              s7 = 0x5BE0CD19
              unquote(compress())
          end

        w[0] = s0
        w[1] = s1
        w[2] = s2
        w[3] = s3
        w[4] = s4
        w[5] = s5
        w[6] = s6
        w[7] = s7

        for i <- 0..(len(seed) - 1)//1, n <= 0 do
          out[i] = seed[i]
        end

        for i <- 0..31//1, n > 0 do
          out[i] = band(bsr(w[div(i, 4)], 24 - 8 * rem(i, 4)), 255)
        end

        out
      end

      # HMAC-SHA256(key, client <> ":" <> Integer.to_string(nonce)) for nonce
      # = first..first + n - 1, the digests packed back to back (32 bytes
      # each). The key's two padded blocks are compressed once per call, so
      # each round costs the inner blocks (one while the message is under 56
      # bytes) and one outer block. A negative nonce raises (alloc(u8, -1)).
      defk hmac_sha256_rounds(key :: [u8], client :: [u8], first :: i64, n :: i64) :: [u8] do
        kh = sha256(key)
        ipad = alloc(u8, 64)
        opad = alloc(u8, 64)

        for i <- 0..63//1 do
          kb =
            if len(key) > 64,
              do: if(i < 32, do: kh[i], else: 0),
              else: if(i < len(key), do: key[i], else: 0)

          ipad[i] = bxor(kb, 0x36)
          opad[i] = bxor(kb, 0x5C)
        end

        unquote_splicing(elem(ipad_step, 0))
        {i0, i1, i2, i3, i4, i5, i6, i7} = {unquote_splicing(elem(ipad_step, 1))}
        unquote_splicing(elem(opad_step, 0))
        {o0, o1, o2, o3, o4, o5, o6, o7} = {unquote_splicing(elem(opad_step, 1))}

        cl = len(client)
        # client, ':', up to 19 digits, 0x80 and the 8-byte length
        mbuf = alloc(u8, (div(cl + 20 + 8, 64) + 1) * 64)

        for i <- 0..(cl - 1)//1 do
          mbuf[i] = client[i]
        end

        mbuf[cl] = 58
        out = alloc(u8, 32 * max(n, 0))
        _ = alloc(u8, if(first < 0 and n > 0, do: -1, else: 0))

        for r <- 0..(n - 1)//1 do
          nonce = first + r

          {nd, _} =
            for _ <- 1..19//1, reduce: {0, nonce} do
              {d, x} -> {if(x > 0 or d == 0, do: d + 1, else: d), div(x, 10)}
            end

          for i <- 0..(nd - 1)//1, reduce: nonce do
            x ->
              mbuf[cl + nd - i] = rem(x, 10) + 48
              div(x, 10)
          end

          l = cl + 1 + nd
          nb = div(l + 8, 64) + 1

          for i <- (l + 1)..(nb * 64 - 9)//1 do
            mbuf[i] = 0
          end

          mbuf[l] = 128
          bits = (64 + l) * 8

          for j <- 0..7//1 do
            mbuf[nb * 64 - 1 - j] = band(bsr(bits, 8 * j), 255)
          end

          {h0, h1, h2, h3, h4, h5, h6, h7} =
            for blk <- 0..(nb - 1)//1, reduce: {i0, i1, i2, i3, i4, i5, i6, i7} do
              {c0, c1, c2, c3, c4, c5, c6, c7} ->
                unquote_splicing(elem(inner_step, 0))
                {unquote_splicing(elem(inner_step, 1))}
            end

          unquote_splicing(elem(outer_step, 0))
          {d0, d1, d2, d3, d4, d5, d6, d7} = {unquote_splicing(elem(outer_step, 1))}
          o = 32 * r
          unquote_splicing(store)
        end

        out
      end

      # sha256_chain with the compression unrolled (compress_unrolled/2)
      defk sha256_chain_unrolled(seed :: [u8], n :: i64) :: [u8] do
        first = sha256(seed)
        out = alloc(u8, if(n <= 0, do: len(seed), else: 32))
        w = alloc(i64, 8)

        {d0, d1, d2, d3, d4, d5, d6, d7} =
          for _step <- 2..n//1,
              reduce:
                {u32_be(first, 0), u32_be(first, 4), u32_be(first, 8), u32_be(first, 12),
                 u32_be(first, 16), u32_be(first, 20), u32_be(first, 24), u32_be(first, 28)} do
            {d0, d1, d2, d3, d4, d5, d6, d7} ->
              unquote_splicing(elem(chain_step, 0))
              {unquote_splicing(elem(chain_step, 1))}
          end

        w[0] = d0
        w[1] = d1
        w[2] = d2
        w[3] = d3
        w[4] = d4
        w[5] = d5
        w[6] = d6
        w[7] = d7

        for i <- 0..(len(seed) - 1)//1, n <= 0 do
          out[i] = seed[i]
        end

        for i <- 0..31//1, n > 0 do
          out[i] = band(bsr(w[div(i, 4)], 24 - 8 * rem(i, 4)), 255)
        end

        out
      end
    end
  end
end

defmodule HashChain.Kernels do
  use Defk
  use HashChain.Source
end

# Elixir mode is compiled only in :test (or with `config :defk, mode:
# :elixir`); a stub project in :test makes this second copy carry it.
defmodule HashChain.MixStub do
  use Mix.Project
  def project, do: [app: :hash_chain_stub, version: "0.1.0"]
end

prev_env = Mix.env()
Mix.env(:test)

defmodule HashChain.KernelsEM do
  use Defk
  use HashChain.Source
end

Mix.env(prev_env)
Mix.ProjectStack.pop()

defmodule HashChain.Elixir do
  # The three ways to chain :crypto that were measured.
  def reduce(seed, n), do: Enum.reduce(1..n//1, seed, fn _, h -> :crypto.hash(:sha256, h) end)

  def loop(h, n) when n <= 0, do: h
  def loop(h, n), do: loop(:crypto.hash(:sha256, h), n - 1)

  # hash_init once, then update + final on a copy of that context per step
  def ctx(seed, n), do: ctx_loop(seed, n, :crypto.hash_init(:sha256))

  defp ctx_loop(h, n, _c) when n <= 0, do: h

  defp ctx_loop(h, n, c),
    do: ctx_loop(:crypto.hash_final(:crypto.hash_update(c, h)), n - 1, c)

  # HMAC rounds, digests packed back to back: :crypto.mac per round
  def hmac_mac(key, client, first, n) do
    for nonce <- first..(first + n - 1)//1, into: <<>> do
      :crypto.mac(:hmac, :sha256, key, [client, ?:, Integer.to_string(nonce)])
    end
  end

  # HMAC as RFC 2104 spells it, with two plain :crypto.hash calls over the
  # padded key: four compressions instead of two, but on the SHA instructions
  # that is cheaper than the per-call setup of :crypto.mac or a context copy
  def hmac_hash(key, client, first, n) do
    {ip, op} = pads(key)

    for nonce <- first..(first + n - 1)//1, into: <<>> do
      :crypto.hash(:sha256, [
        op | :crypto.hash(:sha256, [ip, client, ?:, Integer.to_string(nonce)])
      ])
    end
  end

  defp pads(key) do
    k = if byte_size(key) > 64, do: :crypto.hash(:sha256, key), else: key
    k = k <> :binary.copy(<<0>>, 64 - byte_size(k))
    {:crypto.exor(k, :binary.copy(<<0x36>>, 64)), :crypto.exor(k, :binary.copy(<<0x5C>>, 64))}
  end

  # HMAC from two hash contexts with the padded key absorbed once (RFC 2104),
  # so a round is update + final on copies of them
  def hmac_ctx(key, client, first, n) do
    {ip, op} = pads(key)
    ictx = :crypto.hash_update(:crypto.hash_init(:sha256), ip)
    octx = :crypto.hash_update(:crypto.hash_init(:sha256), op)

    for nonce <- first..(first + n - 1)//1, into: <<>> do
      inner =
        :crypto.hash_final(:crypto.hash_update(ictx, [client, ?:, Integer.to_string(nonce)]))

      :crypto.hash_final(:crypto.hash_update(octx, inner))
    end
  end
end

alias HashChain.{Kernels, KernelsEM}
alias HashChain.Elixir, as: Ex

# ---------------------------------------------------------------- agreement

hex = &Base.decode16!(&1, case: :mixed)

fips = [
  {"", hex.("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")},
  {"abc", hex.("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")},
  {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
   hex.("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")},
  {"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
   hex.("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")}
]

vectors =
  for {m, want} <- fips do
    {byte_size(m), Kernels.sha256(m) == want, :crypto.hash(:sha256, m) == want,
     KernelsEM.__defk_elixir__(:sha256, [m]) == want}
  end

vectors_ok = Enum.all?(vectors, fn {_, a, b, c} -> a and b and c end)

:rand.seed(:exsss, {18, 9, 6})

# random messages of 0..300 bytes (every padding case: 55, 56, 63, 64 bytes
# and multi-block) against OpenSSL, and against Elixir mode on the short ones
random_ok =
  Enum.all?(
    Enum.to_list(0..130) ++ Enum.map(1..300, fn _ -> :rand.uniform(301) - 1 end),
    fn len ->
      m = :rand.bytes(len)
      d = Kernels.sha256(m)

      d == :crypto.hash(:sha256, m) and
        (len > 70 or d == KernelsEM.__defk_elixir__(:sha256, [m]))
    end
  )

seed = :rand.bytes(32)

# the chain against OpenSSL for n = 0, 1, 2, 1000, from 32-byte and odd seeds,
# and against Elixir mode for short chains
chain_ok =
  for s <- [seed, "", "server seed", :rand.bytes(100)], n <- [-1, 0, 1, 2, 3, 1000] do
    k = Kernels.sha256_chain(s, n)

    k == Ex.reduce(s, n) and k == Ex.loop(s, n) and k == Ex.ctx(s, n) and
      (n > 3 or k == KernelsEM.__defk_elixir__(:sha256_chain, [s, n]))
  end
  |> Enum.all?()

chain_ok =
  chain_ok and
    Enum.all?(
      for s <- [seed, "", :rand.bytes(100)],
          n <- [-1, 0, 1, 2, 1000],
          do: Kernels.sha256_chain_unrolled(s, n) == Ex.loop(s, n)
    )

# HMAC rounds: keys of 0, 32, 64, 65 and 100 bytes (hashed above 64), clients
# that keep the inner message in one block or push it to two, nonces across
# digit-count boundaries, against :crypto.mac and Elixir mode
hmac_ok =
  for key <- ["", :rand.bytes(32), :rand.bytes(64), :rand.bytes(65), :rand.bytes(100)],
      client <- ["", "client seed", String.duplicate("c", 40), String.duplicate("x", 70)],
      {first, n} <- [{0, 12}, {95, 10}, {999_990, 15}, {9_223_372_036_854_775_800, 3}] do
    k = Kernels.hmac_sha256_rounds(key, client, first, n)

    k == Ex.hmac_mac(key, client, first, n) and k == Ex.hmac_ctx(key, client, first, n) and
      k == Ex.hmac_hash(key, client, first, n) and
      k == KernelsEM.__defk_elixir__(:hmac_sha256_rounds, [key, client, first, n])
  end
  |> Enum.all?()

agree = vectors_ok and random_ok and chain_ok and hmac_ok

unless agree,
  do:
    raise("agreement failed: vectors #{inspect(vectors)}, random #{random_ok}, chain #{chain_ok}")

IO.puts(
  "agreement: 4 FIPS 180-4 vectors (0, 3, 56, 112 bytes), 431 random messages of 0..300 bytes vs :crypto, chains n = -1..3 and 1000 from 4 seeds vs :crypto and Elixir mode, HMAC rounds over 5 keys x 4 clients x 4 nonce ranges vs :crypto.mac and Elixir mode: ok"
)

# ---------------------------------------------------------------- timing

best_us = fn f, runs ->
  for _ <- 1..runs, reduce: :infinity do
    acc ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      min(acc, us)
  end
end

row = fn label, f, n, runs ->
  us = best_us.(f, runs)

  IO.puts(
    "  #{String.pad_trailing(label, 44)} #{:erlang.float_to_binary(us / 1000, decimals: 1)} ms  #{:erlang.float_to_binary(us * 1000 / n, decimals: 0)} ns/step"
  )
end

# The variants at 1M steps (the report below measures the fastest of each
# side at the realistic size).
mid = 1_000_000
want_mid = Ex.loop(seed, mid)
IO.puts("chain of #{mid} steps from a 32-byte seed, best of 5:")

for {label, f} <- [
      {"Enum.reduce over :crypto.hash/2", fn -> Ex.reduce(seed, mid) end},
      {"tail-recursive loop over :crypto.hash/2", fn -> Ex.loop(seed, mid) end},
      {":crypto.hash_init once, update + final", fn -> Ex.ctx(seed, mid) end},
      {"defk sha256_chain (rounds as loops)", fn -> Kernels.sha256_chain(seed, mid) end},
      {"defk sha256_chain_unrolled", fn -> Kernels.sha256_chain_unrolled(seed, mid) end}
    ] do
  true = f.() == want_mid
  row.(label, f, mid, 5)
end

hkey = :rand.bytes(32)
client = "client-seed-0123456789"
IO.puts("HMAC-SHA256 rounds, #{mid} nonces, best of 5:")

for {label, f} <- [
      {":crypto.mac per round", fn -> Ex.hmac_mac(hkey, client, 1, mid) end},
      {"hash contexts with the key absorbed once", fn -> Ex.hmac_ctx(hkey, client, 1, mid) end},
      {"two :crypto.hash calls over the padded key",
       fn -> Ex.hmac_hash(hkey, client, 1, mid) end},
      {"defk hmac_sha256_rounds", fn -> Kernels.hmac_sha256_rounds(hkey, client, 1, mid) end}
    ] do
  row.(label, f, mid, 5)
end

# ---------------------------------------------------------------- reports

big = String.to_integer(System.get_env("HASH_CHAIN_N", "10000000"))
want_big = Ex.loop(seed, big)

r1 =
  Defk.Bench.report(
    name: "hash_chain",
    expected: :poor,
    baseline: :optimized,
    runs: 5,
    realistic_size: "#{big} steps",
    elixir: fn -> Ex.loop(seed, big) end,
    defk: fn -> Kernels.sha256_chain_unrolled(seed, big) end,
    check: fn ->
      agree and Kernels.sha256_chain_unrolled(seed, big) == want_big and
        Kernels.sha256_chain(seed, big) == want_big and Ex.reduce(seed, big) == want_big
    end,
    sweep:
      {[1_000, 100_000, 1_000_000, 10_000_000],
       fn n -> {fn -> Ex.loop(seed, n) end, fn -> Kernels.sha256_chain_unrolled(seed, n) end} end},
    sweep_runs: 3,
    reason:
      ":crypto.hash/2 is OpenSSL using the CPU's SHA-256 instructions, about 100 ns per step including the call; the kernel is portable C with no intrinsics (about 170 ns per compression), and the call overhead it removes is smaller than the instructions it lacks: use :crypto"
  )

hmac_n = 1_000_000

r2 =
  Defk.Bench.report(
    name: "hmac_rounds",
    expected: :marginal,
    baseline: :optimized,
    runs: 5,
    realistic_size: "#{hmac_n} nonces",
    elixir: fn -> Ex.hmac_hash(hkey, client, 1, hmac_n) end,
    defk: fn -> Kernels.hmac_sha256_rounds(hkey, client, 1, hmac_n) end,
    check: fn ->
      agree and
        Kernels.hmac_sha256_rounds(hkey, client, 1, hmac_n) ==
          Ex.hmac_mac(hkey, client, 1, hmac_n)
    end,
    sweep:
      {[1, 100, 10_000, 1_000_000],
       fn n ->
         {fn -> Ex.hmac_hash(hkey, client, 1, n) end,
          fn -> Kernels.hmac_sha256_rounds(hkey, client, 1, n) end}
       end},
    sweep_runs: 3,
    reason:
      "two compressions per round in portable C against four on the SHA instructions plus two calls: the kernel saves the calls, the message building and the key-pad compressions, 1.3-1.5x; :crypto.mac per round is 1.7-1.9x slower than that RFC 2104 by hand, from its per-call key setup"
  )

bad = for r <- [r1, r2], not r.correct or r.verdict != r.expected, do: r.example

unless bad == [],
  do:
    (
      IO.puts("verdict or agreement mismatch: #{inspect(bad)}")
      System.halt(1)
    )
