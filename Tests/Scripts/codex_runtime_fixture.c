// Synthetic app-server / open-file writer. No client accounts or network access.
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (strcmp(argv[1], "app-server") == 0) {
        char line[8192];
        while (fgets(line, sizeof(line), stdin)) {
            if (strstr(line, "clientInfo")) puts("{\"id\":1,\"result\":{}}");
            else if (strstr(line, "thread/list") || strstr(line, "thread\\/list")) {
                if (argc > 3 && strcmp(argv[3], "invalid") == 0)
                    puts("{\"id\":2,\"error\":{\"code\":-32603,\"message\":\"fixture failure\"}}");
                else puts("{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null}}");
            }
            fflush(stdout);
        }
        return 0;
    }
    int fd = open(argv[1], O_WRONLY | O_APPEND);
    if (fd < 0 || write(STDOUT_FILENO, "R", 1) != 1) return 3;
    char end;
    read(STDIN_FILENO, &end, 1);
    close(fd);
    return 0;
}
