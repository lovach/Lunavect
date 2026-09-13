// Self-contained workload; getrusage is the independent CPU-time reference.
#include <assert.h>
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>
#include "../../scripts/performance/mach-time.h"

static double cpu_seconds(void) {
    struct rusage usage;
    assert(getrusage(RUSAGE_SELF, &usage) == 0);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

int main(void) {
    uint64_t ns;
    assert(ticks_to_nanoseconds(7200186, 125, 3, &ns) && ns == 300007750);
    assert(ticks_to_nanoseconds(UINT64_MAX, 1, 1, &ns) && ns == UINT64_MAX);
    assert(ticks_to_nanoseconds(UINT64_MAX, 3, 3, &ns) && ns == UINT64_MAX);
    assert(ticks_to_nanoseconds(1, 125, 3, &ns) && ns == 41);
    assert(!ticks_to_nanoseconds(UINT64_MAX, 125, 3, &ns));
    assert(!ticks_to_nanoseconds(1, 0, 1, &ns));
    assert(!ticks_to_nanoseconds(1, 1, 0, &ns));
    puts("ready"); fflush(stdout);
    if (getchar() == EOF) return 1;
    double start = cpu_seconds();
    while (cpu_seconds() - start < 0.25) {
        for (volatile int i = 0; i < 10000; ++i) {}
    }
    printf("%.9f\n", cpu_seconds() - start); fflush(stdout);
    (void)getchar();
    return 0;
}
