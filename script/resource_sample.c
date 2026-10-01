#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/resource.h>
#include <mach/mach_time.h>

// Read-only, bounded process-family sampler. RSS counts shared mappings repeatedly.
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    pid_t pids[512] = {(pid_t)atoi(argv[1])};
    int count = 1, measured = 0;
    uint64_t rss = 0, footprint = 0, cpu = 0, wakeups = 0, reads = 0, writes = 0;
    for (int i = 0; i < count; i++) {
        pid_t children[512];
        int n = proc_listchildpids(pids[i], children, sizeof(children));
        for (int j = 0; j < n && j < 512 && count < 512; j++) {
            int seen = 0;
            for (int k = 0; k < count; k++) seen |= pids[k] == children[j];
            if (!seen && children[j] > 0) pids[count++] = children[j];
        }
        struct rusage_info_v4 info = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&info)) continue;
        measured++;
        rss += info.ri_resident_size;
        footprint += info.ri_phys_footprint;
        cpu += info.ri_user_time + info.ri_system_time;
        wakeups += info.ri_interrupt_wkups;
        reads += info.ri_diskio_bytesread;
        writes += info.ri_diskio_byteswritten;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    printf("{\"processes\":%d,\"rssMiB\":%.3f,\"footprintMiB\":%.3f,\"cpuSeconds\":%.6f,\"interruptWakeups\":%llu,\"diskReadBytes\":%llu,\"diskWriteBytes\":%llu}\n",
           measured, rss / 1048576.0, footprint / 1048576.0, cpu * (double)timebase.numer / timebase.denom / 1e9,
           (unsigned long long)wakeups, (unsigned long long)reads, (unsigned long long)writes);
    return measured ? 0 : 1;
}
