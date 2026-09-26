#include "p4w_proc.h"

#include <libproc.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>

static int read_rusage(pid_t pid, struct rusage_info_v4 *out) {
    if (pid <= 0 || out == NULL) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    int rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)out);
    return rc == 0 ? 0 : -1;
}

int64_t p4w_phys_footprint(pid_t pid) {
    struct rusage_info_v4 info;
    if (read_rusage(pid, &info) != 0) {
        return -1;
    }
    return (int64_t)info.ri_phys_footprint;
}

int64_t p4w_resident_size(pid_t pid) {
    struct rusage_info_v4 info;
    if (read_rusage(pid, &info) != 0) {
        return -1;
    }
    return (int64_t)info.ri_resident_size;
}

int p4w_list_children(pid_t pid, pid_t *buffer, int maxCount) {
    if (pid <= 0 || buffer == NULL || maxCount <= 0) {
        return -1;
    }
    int bytes = proc_listchildpids(pid, buffer, (int)(sizeof(pid_t) * (size_t)maxCount));
    if (bytes < 0) {
        return -1;
    }
    return bytes / (int)sizeof(pid_t);
}

// Mismo recorrido que p4w_list_descendants, pero devuelve también el orden de visita
// para poder señalizar de hoja hacia la raíz.
static int collect_descendants(pid_t pid, pid_t *buffer, int maxCount) {
    pid_t queue[1024];
    int queueCount = 0;
    queue[queueCount++] = pid;

    int written = 0;
    for (int head = 0; head < queueCount; head++) {
        pid_t kids[256];
        int n = p4w_list_children(queue[head], kids, 256);
        if (n <= 0) {
            continue;
        }
        for (int i = 0; i < n; i++) {
            if (kids[i] <= 1) {
                continue;  // nunca señalar pid 0 ni launchd
            }
            if (written < maxCount) {
                buffer[written++] = kids[i];
            }
            if (queueCount < 1024) {
                queue[queueCount++] = kids[i];
            }
        }
    }
    return written;
}

int p4w_list_descendants(pid_t pid, pid_t *buffer, int maxCount) {
    if (pid <= 0 || buffer == NULL || maxCount <= 0) {
        return -1;
    }
    return collect_descendants(pid, buffer, maxCount);
}

int p4w_terminate_tree(pid_t pid, int signal) {
    if (pid <= 0) {
        return -1;
    }

    pid_t descendants[1024];
    int count = collect_descendants(pid, descendants, 1024);
    if (count < 0) {
        return -1;
    }

    // De hoja hacia la raíz: el orden de visita es en anchura, así que se recorre al revés.
    for (int i = count - 1; i >= 0; i--) {
        kill(descendants[i], signal);
    }
    kill(pid, signal);
    return count + 1;
}
