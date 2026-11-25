#import "OTACrashMarker.h"

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

static const int kCrashSignals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE};
static const int kCrashSignalCount = sizeof(kCrashSignals) / sizeof(kCrashSignals[0]);

static volatile sig_atomic_t gMarkerFd = -1;
static struct sigaction gPreviousActions[NSIG];
static NSUncaughtExceptionHandler *gPreviousExceptionHandler;
static pthread_mutex_t gInstallLock = PTHREAD_MUTEX_INITIALIZER;
static bool gInstalled;

// Async-signal-safe: write and fsync on a descriptor opened before the crash.
static void NottiOtaMarkCrash(void)
{
  int fd = gMarkerFd;
  if (fd < 0) {
    return;
  }
  static const char mark[] = "crash\n";
  (void)write(fd, mark, sizeof(mark) - 1);
  (void)fsync(fd);
}

static void NottiOtaOnSignal(int signo, siginfo_t *info, void *context)
{
  NottiOtaMarkCrash();
  struct sigaction previous = gPreviousActions[signo];
  sigaction(signo, &previous, NULL);
  if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction != NULL) {
    previous.sa_sigaction(signo, info, context);
  } else if (!(previous.sa_flags & SA_SIGINFO) && previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN) {
    previous.sa_handler(signo);
  } else if (previous.sa_handler == SIG_DFL) {
    raise(signo);
  }
}

static void NottiOtaOnUncaughtException(NSException *exception)
{
  NottiOtaMarkCrash();
  if (gPreviousExceptionHandler != NULL) {
    gPreviousExceptionHandler(exception);
  }
}

void NottiOtaCrashMarkerInstall(void)
{
  pthread_mutex_lock(&gInstallLock);
  if (!gInstalled) {
    gInstalled = true;
    gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&NottiOtaOnUncaughtException);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    action.sa_sigaction = NottiOtaOnSignal;
    for (int i = 0; i < kCrashSignalCount; i++) {
      sigaction(kCrashSignals[i], &action, &gPreviousActions[kCrashSignals[i]]);
    }
  }
  pthread_mutex_unlock(&gInstallLock);
}

void NottiOtaCrashMarkerUninstallForTests(void)
{
  pthread_mutex_lock(&gInstallLock);
  if (gInstalled) {
    gInstalled = false;
    NSSetUncaughtExceptionHandler(gPreviousExceptionHandler);
    for (int i = 0; i < kCrashSignalCount; i++) {
      sigaction(kCrashSignals[i], &gPreviousActions[kCrashSignals[i]], NULL);
    }
  }
  pthread_mutex_unlock(&gInstallLock);
  NottiOtaCrashMarkerDisarm();
}

bool NottiOtaCrashMarkerArm(const char *path)
{
  NottiOtaCrashMarkerDisarm();
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    return false;
  }
  gMarkerFd = fd;
  return true;
}

void NottiOtaCrashMarkerDisarm(void)
{
  int fd = gMarkerFd;
  gMarkerFd = -1;
  if (fd >= 0) {
    close(fd);
  }
}
