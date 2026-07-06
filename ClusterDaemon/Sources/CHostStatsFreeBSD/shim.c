#include "CHostStatsFreeBSD.h"

#if defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <stdlib.h>

int ehs_sysctl_u64(const char *name, uint64_t *out) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0) return -1;
    if (size == sizeof(uint64_t)) {
        uint64_t v = 0; size = sizeof(v);
        if (sysctlbyname(name, &v, &size, NULL, 0) != 0) return -1;
        *out = v;
        return 0;
    }
    if (size == sizeof(uint32_t)) {
        uint32_t v = 0; size = sizeof(v);
        if (sysctlbyname(name, &v, &size, NULL, 0) != 0) return -1;
        *out = (uint64_t)v;
        return 0;
    }
    return -1;
}

int ehs_sysctl_str(const char *name, char *buf, size_t buflen) {
    if (buflen == 0) return -1;
    size_t size = buflen;
    if (sysctlbyname(name, buf, &size, NULL, 0) != 0) return -1;
    buf[buflen - 1] = '\0';
    return 0;
}

int ehs_cpu_ticks(uint64_t ticks[5]) {
    long cp[5] = { 0, 0, 0, 0, 0 };
    size_t size = sizeof(cp);
    if (sysctlbyname("kern.cp_time", cp, &size, NULL, 0) != 0) return -1;
    for (int i = 0; i < 5; i++) ticks[i] = (uint64_t)cp[i];
    return 0;
}

int ehs_boottime(double *out) {
    struct timeval bt;
    size_t size = sizeof(bt);
    if (sysctlbyname("kern.boottime", &bt, &size, NULL, 0) != 0) return -1;
    if (bt.tv_sec <= 0) return -1;
    *out = (double)bt.tv_sec + (double)bt.tv_usec / 1000000.0;
    return 0;
}

long ehs_process_count(void) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_PROC };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return -1;
    len += len / 8 + 16384;             /* slack for procs spawned since sizing */
    void *buf = malloc(len);
    if (buf == NULL) return -1;
    if (sysctl(mib, 3, buf, &len, NULL, 0) != 0 || len < sizeof(int)) {
        free(buf);
        return -1;
    }
    /* Every kinfo_proc entry is the same size, and its first field —
       ki_structsize — is exactly that size, so we needn't know the struct. */
    int struct_size = *(const int *)buf;
    long count = (struct_size > 0) ? (long)(len / (size_t)struct_size) : -1;
    free(buf);
    return count;
}

#else  /* not FreeBSD: stubs so the C target builds on every platform */

int  ehs_sysctl_u64(const char *name, uint64_t *out) { (void)name; (void)out; return -1; }
int  ehs_sysctl_str(const char *name, char *buf, size_t buflen) { (void)name; (void)buf; (void)buflen; return -1; }
int  ehs_cpu_ticks(uint64_t ticks[5]) { (void)ticks; return -1; }
int  ehs_boottime(double *out) { (void)out; return -1; }
long ehs_process_count(void) { return -1; }

#endif
