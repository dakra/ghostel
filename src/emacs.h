// Ensure struct timespec is fully defined on Linux (glibc gates it
// behind _POSIX_C_SOURCE).  Harmless on macOS/BSDs.
#define _POSIX_C_SOURCE 199309L
#include <emacs-module.h>
