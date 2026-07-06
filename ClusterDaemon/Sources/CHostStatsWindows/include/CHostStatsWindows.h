#ifndef C_HOST_STATS_WINDOWS_H
#define C_HOST_STATS_WINDOWS_H

#include <stdint.h>

// Thin C shim over the two PSAPI calls the Swift `WinSDK` overlay doesn't
// surface: `EnumProcesses` and `GetProcessMemoryInfo` live in <psapi.h> and, on
// modern SDKs (PSAPI_VERSION 2), are macro-renamed to `K32*` — Swift can't
// import function-like macros, so it sees neither name. The C preprocessor
// resolves them fine, so the calls live here. Every other Win32 API this daemon
// uses is reachable straight from `import WinSDK`.
//
// Only Windows implements these; elsewhere they're stubs returning -1, so the
// target still builds (SwiftPM compiles all targets on all platforms). Keeping
// <windows.h>/<psapi.h> in the .c file and OUT of this header keeps the
// Swift-visible module free of system headers.

// Live process count, or -1 on failure.
int ehs_win_process_count(void);

// Current process working set + pagefile usage in bytes. 0 on success, -1 on fail.
int ehs_win_working_set(uint64_t *residentBytes, uint64_t *pagefileBytes);

#endif /* C_HOST_STATS_WINDOWS_H */
