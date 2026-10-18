---
modules: [Defk, Defk.Build]
---

## Purpose

The runtime contract is one of the four surfaces of the stability promise
(`docs/guides/stability.md`, "The runtime contract"): what a kernel promises
the BEAM while it runs, so that it can never starve or crash the node.
`docs/guides/runtime-contract.md` states its four promises: preemption,
isolation, cleanup and hot code upgrade.

Not promised, and so not obligations here: the numbers that tune the
promises (the length of a slice, how often the clock is read, the default
owned-buffer budget, the adaptive slice), the counters' exact values, and
where isolation stops (a fault in the C library or the VM, a wild write that
does not fault, Windows).

### defk.runtime_contract.I1 — A long kernel yields, and yielding never changes a result
- **scope:** every kernel with a loop; `yield: false`; kernels without loops
- **must:** a kernel whose loop runs long yields to its scheduler during the call and returns the result it returns with a forced yield at every safepoint; a kernel with no loop, and a kernel compiled with `yield: false`, never yield
- **why:** a NIF that runs for milliseconds blocks its scheduler; the kernel shares it instead, and the caller cannot tell
- **kind:** non-functional
- **status:** active

### defk.runtime_contract.I2 — Concurrent calls share nothing
- **scope:** one kernel called from many processes at once, some calls suspended
- **must:** each caller gets the result it would get alone, also with a forced yield at every safepoint, and once every caller is done no frame of the kernel is left live
- **why:** suspended calls interleave on the schedulers; a call that saw another call's state would break the one rule
- **kind:** functional
- **status:** active

### defk.runtime_contract.I3 — A runtime error is an ordinary exception in the caller
- **scope:** array reads and writes, checked arithmetic, a kernel's own `raise`; the caller's arguments
- **must:** an index out of range raises `Enum.OutOfBoundsError`, an integer overflow raises `ArithmeticError`, a kernel's `raise` raises its exception, each in the calling process, where `rescue` catches it; a write to an input array never changes the caller's binary
- **why:** a kernel touches only its own arguments and the arrays it allocates; a bad index is an exception, as in Elixir, never a read or write outside the array
- **kind:** security
- **status:** active

### defk.runtime_contract.I4 — A fault in kernel code is a RuntimeError, and the node keeps running
- **scope:** a synchronous fault (segmentation fault, illegal instruction) inside a kernel's native code, also after the kernel yielded
- **must:** the call raises `RuntimeError` whose message starts with "defk bug" in the calling process only, after the kernel's buffers are freed; other processes and the library keep working
- **why:** a crash in a NIF takes the whole node down; a defk kernel faulting would be a defk bug, and it costs one call, not the node
- **kind:** security
- **status:** active

### defk.runtime_contract.I5 — A call frees its memory, however it ends
- **scope:** `alloc/2` and copies; a normal return, a raise, a process killed while its kernel is suspended
- **must:** after a raise every owned buffer is freed and no frame is left live, also when the raise happens after the kernel yielded; a process killed while its kernel is suspended frees its frame; `alloc/2` raises `ArgumentError` for a length over 2^48 bytes
- **why:** a long-running node calls kernels millions of times; a leak per raise or per killed process would end it
- **kind:** non-functional
- **status:** active

### defk.runtime_contract.I6 — A suspended kernel finishes in its own code across a hot upgrade
- **scope:** recompiling a kernel module while one of its kernels is suspended; `:code.purge/1`
- **must:** the suspended call finishes in the library it started in, with that library's result; new calls run the new code; each library frees only its own frames; reloading the same source keeps the library; purging the old code kills the suspended process, like any process in old code; a new library's counters start at zero while the old call counts in the old one
- **why:** hot code upgrade is a BEAM promise; a kernel must not break it by resuming in code that changed under it
- **kind:** functional
- **status:** active
