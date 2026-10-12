#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

extern char **environ;

static void fail(const char *msg, int err) {
    const char *reason = strerror(err);
    write(STDERR_FILENO, msg, strlen(msg));
    write(STDERR_FILENO, ": ", 2);
    write(STDERR_FILENO, reason, strlen(reason));
    _exit(1);
}

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) != 0)
        fail("Failed to set up PTY replica", errno);
    execve(argv[1], argv + 2, environ);
    fail("Failed to start subprocess", errno);
    return 1;
}
