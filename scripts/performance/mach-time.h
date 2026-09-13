#ifndef LUNAVECT_MACH_TIME_H
#define LUNAVECT_MACH_TIME_H
#include <stdint.h>
#include <stdbool.h>

// libproc CPU counters use Mach absolute ticks, including on Apple silicon.
// Widen before multiplying; reject an unrepresentable nanosecond counter.
static inline bool ticks_to_nanoseconds(uint64_t ticks, uint32_t numer,
                                       uint32_t denom, uint64_t *result) {
    if (!numer || !denom) return false;
    __uint128_t value = (__uint128_t)ticks * numer / denom;
    if (value > UINT64_MAX) return false;
    *result = (uint64_t)value;
    return true;
}
#endif
