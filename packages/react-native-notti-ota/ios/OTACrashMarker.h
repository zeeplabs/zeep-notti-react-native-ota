#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs, once per process, the chained crash handlers: the uncaught NSException handler and
/// the SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE actions. The previous handlers always
/// run after the marker is written.
void NottiOtaCrashMarkerInstall(void);

/// Opens (and truncates) `path` so a crash can mark it without allocating. False when it fails.
bool NottiOtaCrashMarkerArm(const char *path);

/// Stops marking crashes and closes the file opened by `NottiOtaCrashMarkerArm`.
void NottiOtaCrashMarkerDisarm(void);

/// Restores the handlers that were in place before `NottiOtaCrashMarkerInstall`. Tests only.
void NottiOtaCrashMarkerUninstallForTests(void);

#ifdef __cplusplus
}
#endif
