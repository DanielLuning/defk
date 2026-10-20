/*
 * The runtime's error messages, generated from Defk.Messages
 * (lib/defk/messages.ex) by `mix defk.docs`: do not edit. Each define
 * is a printf format; the runtime header passes it to defk_fail with the
 * values of its holes.
 */
#ifndef DEFK_MESSAGES_H
#define DEFK_MESSAGES_H

/* ArithmeticError */
#define DEFK_MSG_I64_OVERFLOW "i64 overflow in %lld %s %lld"
#define DEFK_MSG_I64_OVERFLOW_SHIFT "i64 overflow in %s(%lld, %lld)"
#define DEFK_MSG_I64_OVERFLOW_DIV "i64 overflow in div/2"
#define DEFK_MSG_DIV_BY_ZERO "div/2 by zero"
#define DEFK_MSG_REM_BY_ZERO "rem/2 by zero"
#define DEFK_MSG_U64_OVERFLOW "u64 overflow in %llu %s %llu"
#define DEFK_MSG_U64_OVERFLOW_SHIFT "u64 overflow in %s(%llu, %lld)"
#define DEFK_MSG_U64_TO_I64 "%llu does not fit in i64"
#define DEFK_MSG_I64_TO_U64 "%lld does not fit in u64"
#define DEFK_MSG_WBSL_NEGATIVE "bsl/2 by the negative count %lld inside a mask"
#define DEFK_MSG_RANGE_LIMIT "range element %lld is within one step of the i64 limit (stepping past it overflows)"
#define DEFK_MSG_TRUNC_FIT "trunc/1: %g does not fit in i64"
#define DEFK_MSG_FLOAT_DIV_ZERO "bad argument in arithmetic expression: division by zero"
#define DEFK_MSG_FLOAT_NONFINITE "float result of %.17g %c %.17g is inf or NaN"
#define DEFK_MSG_FLOAT_NONFINITE_LOST "float result is inf or NaN"
#define DEFK_MSG_FLOAT_CALL_NONFINITE_1 "float result of %s(%.17g) is inf or NaN"
#define DEFK_MSG_FLOAT_CALL_NONFINITE_2 "float result of %s(%.17g, %.17g) is inf or NaN"
#define DEFK_MSG_SQRT_NEGATIVE "sqrt of negative number %g"
#define DEFK_MSG_LOG_NON_POSITIVE "log of non-positive number %g"
#define DEFK_MSG_LOG2_NON_POSITIVE "log2 of non-positive number %g"
#define DEFK_MSG_LOG10_NON_POSITIVE "log10 of non-positive number %g"
#define DEFK_MSG_NONFINITE_RESULT "kernel produced a non-finite float"

/* ArgumentError */
#define DEFK_MSG_ARG_BINARY "argument %d (%s) must be a binary of packed %s"
#define DEFK_MSG_ARG_SIZE "argument %d (%s): byte size %zu is not a multiple of %zu (%s)"
#define DEFK_MSG_ARG_I64 "argument %d (%s) must be an integer fitting in i64"
#define DEFK_MSG_ARG_F64 "argument %d (%s) must be a number"
#define DEFK_MSG_ARG_U64 "argument %d (%s) must be an integer fitting in u64"
#define DEFK_MSG_ARG_BOOL "argument %d (%s) must be a boolean"
#define DEFK_MSG_ALLOC_NEGATIVE "alloc/2: negative length %lld"
#define DEFK_MSG_ALLOC_TOO_LARGE "alloc/2: length too large"
#define DEFK_MSG_OUT_OF_MEMORY "out of memory"
#define DEFK_MSG_OUT_OF_MEMORY_BYTES "out of memory (allocating %zu bytes)"
#define DEFK_MSG_OVER_BUDGET "out of memory (allocating %zu bytes would take this call's buffers past max_owned_bytes, %llu bytes)"
#define DEFK_MSG_RAISE_MESSAGE_OOM "out of memory building a raise message"
#define DEFK_MSG_COPY_NEGATIVE "%s: negative length %lld"
#define DEFK_MSG_COPY_BACK_OFFSET "copy_back/4: offset %lld is not positive"
#define DEFK_MSG_BITS_WIDTH "Defk.Bits.%s: width %lld is not in 1..64"
#define DEFK_MSG_BITS_FIELD "Defk.Bits.%s: %lld does not fit in a %lld-bit field"
#define DEFK_MSG_BITS_FIELD_U64 "Defk.Bits.%s: %llu does not fit in a %lld-bit field"
#define DEFK_MSG_CRC32C_WIDTH "Defk.Bits.crc32c/3: width %lld is not 8, 16, 32 or 64"
#define DEFK_MSG_NONFINITE_INPUT "non-finite float (inf or NaN) read from an input array at index %lld"
#define DEFK_MSG_VALUE_U8 "value %lld does not fit in u8"
#define DEFK_MSG_VALUE_I16 "value %lld does not fit in i16"
#define DEFK_MSG_VALUE_I32 "value %lld does not fit in i32"
#define DEFK_MSG_VALUE_U64 "value %lld does not fit in u64"
#define DEFK_MSG_VALUE_I64 "value %llu does not fit in i64"
#define DEFK_MSG_VALUE_F32 "value %.17g does not fit in f32"
#define DEFK_MSG_BITSTRING_TOO_LARGE "bitstring too large"
#define DEFK_MSG_SEGMENT_SIZE "bitstring segment size %lld is outside 0..64"
#define DEFK_MSG_SEGMENT_FIT "bitstring segment value %lld does not fit in %lld%s bits"
#define DEFK_MSG_SEGMENT_FIT_U64 "bitstring segment value %llu does not fit in %lld bits"
#define DEFK_MSG_FOREIGN_FRAME "defk: suspended kernel frame has a foreign layout (layout tag mismatch)"

/* Enum.OutOfBoundsError */
#define DEFK_MSG_OOB "index %lld out of bounds for array of length %lld"
#define DEFK_MSG_OOB_LOAD "%d-byte load at index %lld out of bounds for array of length %lld"
#define DEFK_MSG_COPY_OOB "%s: %lld elements %s index %lld out of bounds for %s of length %lld"
#define DEFK_MSG_COPY_BACK_BEFORE_START "copy_back/4: offset %lld from index %lld is before the start of the array"

/* RuntimeError */
#define DEFK_MSG_LOST_RESUME_YIELDED "defk bug: kernel resumed at safepoint %d but yielded at safepoint %d without reaching it (missing or wrong resume dispatch)"
#define DEFK_MSG_LOST_RESUME_RETURNED "defk bug: kernel resumed at safepoint %d but returned without reaching it (missing or wrong resume dispatch)"
#define DEFK_MSG_FAULT "defk bug: %s inside kernel native code (signal %d, code %d, address %p, pc +0x%lx); the call was aborted and the node kept running"

#endif
