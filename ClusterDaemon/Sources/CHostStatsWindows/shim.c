#include "CHostStatsWindows.h"

#if defined(_WIN32)

#include <windows.h>
#include <psapi.h>

int ehs_win_process_count(void) {
    DWORD pids[4096];
    DWORD needed = 0;
    if (!EnumProcesses(pids, (DWORD)sizeof(pids), &needed)) return -1;
    return (int)(needed / sizeof(DWORD));
}

int ehs_win_working_set(uint64_t *residentBytes, uint64_t *pagefileBytes) {
    PROCESS_MEMORY_COUNTERS pmc;
    pmc.cb = (DWORD)sizeof(pmc);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, pmc.cb)) return -1;
    if (residentBytes) *residentBytes = (uint64_t)pmc.WorkingSetSize;
    if (pagefileBytes) *pagefileBytes = (uint64_t)pmc.PagefileUsage;
    return 0;
}

#else  /* not Windows: stubs so the C target builds on every platform */

int ehs_win_process_count(void) { return -1; }
int ehs_win_working_set(uint64_t *residentBytes, uint64_t *pagefileBytes) {
    (void)residentBytes; (void)pagefileBytes; return -1;
}

#endif
