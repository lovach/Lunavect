// Read-only libproc snapshot. Never reads process arguments, memory or open files.
#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <mach/mach_time.h>
#include "mach-time.h"

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char wanted[PATH_MAX], actual[PROC_PIDPATHINFO_MAXSIZE], resolved[PATH_MAX];
    char *end = NULL;
    long number = strtol(argv[2], &end, 10);
    if (!end || *end || number <= 0 || number > INT_MAX || !realpath(argv[1], wanted)) return 2;
    int pid = (int)number;
    if (proc_pidpath(pid, actual, sizeof(actual)) <= 0 || !realpath(actual, resolved)) return 3;
    if (strcmp(wanted, resolved) != 0) return 4;
    struct rusage_info_v4 info = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return 5;
    // Recheck identity after the snapshot as well as before it.
    if (proc_pidpath(pid, actual, sizeof(actual)) <= 0 || !realpath(actual, resolved) || strcmp(wanted, resolved)) return 3;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 5;
    mach_timebase_info_data_t timebase;
    uint64_t user_ns, system_ns;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
        !ticks_to_nanoseconds(info.ri_user_time, timebase.numer, timebase.denom, &user_ns) ||
        !ticks_to_nanoseconds(info.ri_system_time, timebase.numer, timebase.denom, &system_ns)) return 6;
    printf("{\"schema_version\":2,\"cpu_counter_unit\":\"nanoseconds\","
           "\"mach_timebase_numer\":%u,\"mach_timebase_denom\":%u,"
           "\"pid\":%d,\"start_identity\":%llu,\"monotonic_seconds\":%.9f,"
           "\"cpu_user_ns\":%llu,\"cpu_system_ns\":%llu,\"rss_bytes\":%llu,"
           "\"physical_footprint_bytes\":%llu,\"disk_read_bytes\":%llu,\"disk_write_bytes\":%llu,"
           "\"interrupt_wakeups\":%llu,\"platform_idle_wakeups\":%llu}\n",
           timebase.numer, timebase.denom,
           pid, (unsigned long long)info.ri_proc_start_abstime, now.tv_sec + now.tv_nsec / 1e9,
           (unsigned long long)user_ns, (unsigned long long)system_ns,
           (unsigned long long)info.ri_resident_size, (unsigned long long)info.ri_phys_footprint,
           (unsigned long long)info.ri_diskio_bytesread, (unsigned long long)info.ri_diskio_byteswritten,
           (unsigned long long)info.ri_interrupt_wkups, (unsigned long long)info.ri_pkg_idle_wkups);
    return 0;
}
