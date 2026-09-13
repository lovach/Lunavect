// This probe handles synthetic paths only. A failed probe prevents SwiftUI execution.
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int denied_errno(int value) { return value == EPERM || value == EACCES; }
static int check(int condition, const char *name) {
    printf("%s: %s\n", name, condition ? "passed" : "failed");
    return !condition;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int failures = 0;
    int fd = open(argv[1], O_RDONLY);
    failures += check(fd == -1 && denied_errno(errno), "forbidden-file-read");
    if (fd >= 0) close(fd);
    fd = open(argv[1], O_WRONLY);
    failures += check(fd == -1 && denied_errno(errno), "forbidden-file-write");
    if (fd >= 0) close(fd);
    pid_t child = fork();
    if (child == 0) _exit(0);
    failures += check(child == -1 && denied_errno(errno), "child-process-fork");
    if (child > 0) waitpid(child, NULL, 0);
    char *child_argv[] = {"/usr/bin/true", NULL};
    int spawn_error = posix_spawn(&child, child_argv[0], NULL, NULL, child_argv, environ);
    failures += check(denied_errno(spawn_error), "child-process-exec");
    if (spawn_error == 0) waitpid(child, NULL, 0);
    fd = socket(AF_INET, SOCK_STREAM, 0);
    int socket_error = errno;
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(9)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = fd == -1 ? -1 : connect(fd, (struct sockaddr *)&address, sizeof(address));
    failures += check(result == -1 && denied_errno(fd == -1 ? socket_error : errno), "network-connect");
    if (fd >= 0) close(fd);
    const char *services[] = {"com.apple.cfprefsd.agent", "com.apple.cfprefsd.daemon"};
    for (int i = 0; i < 2; i++) {
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, services[i], &service);
        failures += check(kr == BOOTSTRAP_NOT_PRIVILEGED, services[i]);
        if (service != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), service);
    }
    CFStringRef domain = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
    CFPropertyListRef canary = CFPreferencesCopyAppValue(CFSTR("canary"), domain);
    failures += check(canary == NULL, "preferences-canary-read");
    if (canary != NULL) CFRelease(canary);
    CFPreferencesSetAppValue(CFSTR("probe-write"), CFSTR("synthetic"), domain);
    failures += check(!CFPreferencesAppSynchronize(domain), "preferences-persistent-write");
    CFRelease(domain);
    return failures ? 1 : 0;
}
