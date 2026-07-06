#ifndef C_HOST_STATS_FREEBSD_H
#define C_HOST_STATS_FREEBSD_H

#include <stdint.h>
#include <stddef.h>

// Thin C shim over FreeBSD's sysctl(3). The Swift `Glibc` overlay on FreeBSD
// does NOT surface <sys/sysctl.h> (unlike getmntinfo/getrusage/getloadavg/
// sysconf, which it does), so the pure-Swift HostStats+FreeBSD.swift can't call
// sysctl directly — it goes through these wrappers instead.
//
// Only FreeBSD implements them; on every other platform they're stubs returning
// -1, so this target still builds (SwiftPM compiles all targets on all
// platforms). Keeping <sys/sysctl.h> in the .c file and OUT of this header is
// deliberate: the Swift-visible module then pulls in no system headers, so it
// can't clash with the `Glibc` module the same Swift file also imports.

// 0 on success, -1 on failure. Handles 4- or 8-byte integer OIDs transparently.
int  ehs_sysctl_u64(const char *name, uint64_t *out);

// Reads a string OID into buf (always NUL-terminated). 0 on success, -1 on fail.
int  ehs_sysctl_str(const char *name, char *buf, size_t buflen);

// kern.cp_time widened to u64: [USER, NICE, SYS, INTR, IDLE]. 0 on success.
int  ehs_cpu_ticks(uint64_t ticks[5]);

// Boot instant as Unix epoch seconds (microsecond fraction). 0 on success.
int  ehs_boottime(double *out);

// Live process count, or -1 on failure.
long ehs_process_count(void);

#endif /* C_HOST_STATS_FREEBSD_H */
