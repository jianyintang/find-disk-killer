#include "CFindDiskKillerTrace.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/proc_info.h>

#define FDK_TRACE_MAX_PIDS 32768
#define FDK_TRACE_MAX_THREADS_PER_PROCESS 16384

int fdk_trace_resolve_thread(
    uint64_t thread_id,
    FDKTraceProcessIdentity *identity
) {
    if (thread_id == 0 || identity == NULL) {
        return 0;
    }
    memset(identity, 0, sizeof(*identity));

    int estimated_count = proc_listallpids(NULL, 0);
    if (estimated_count <= 0) {
        return 0;
    }
    int pid_capacity = estimated_count + 256;
    if (pid_capacity > FDK_TRACE_MAX_PIDS) {
        pid_capacity = FDK_TRACE_MAX_PIDS;
    }
    pid_t *pids = calloc((size_t)pid_capacity, sizeof(pid_t));
    if (pids == NULL) {
        return 0;
    }
    int pid_count = proc_listallpids(
        pids,
        pid_capacity * (int)sizeof(pid_t)
    );
    if (pid_count <= 0) {
        free(pids);
        return 0;
    }

    int found = 0;
    for (int index = 0; index < pid_count && !found; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }
        int required_bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, NULL, 0);
        if (required_bytes <= 0) {
            continue;
        }
        size_t thread_count = (size_t)required_bytes / sizeof(uint64_t);
        if (thread_count == 0) {
            continue;
        }
        if (thread_count > FDK_TRACE_MAX_THREADS_PER_PROCESS) {
            thread_count = FDK_TRACE_MAX_THREADS_PER_PROCESS;
        }
        uint64_t *threads = calloc(thread_count, sizeof(uint64_t));
        if (threads == NULL) {
            continue;
        }
        int actual_bytes = proc_pidinfo(
            pid,
            PROC_PIDLISTTHREADS,
            0,
            threads,
            (int)(thread_count * sizeof(uint64_t))
        );
        int actual_count = actual_bytes > 0
            ? actual_bytes / (int)sizeof(uint64_t)
            : 0;
        for (int thread_index = 0; thread_index < actual_count; thread_index++) {
            if (threads[thread_index] != thread_id) {
                continue;
            }
            struct rusage_info_v4 usage = {0};
            if (proc_pid_rusage(
                pid,
                RUSAGE_INFO_V4,
                (rusage_info_t *)&usage
            ) != 0) {
                break;
            }
            identity->pid = pid;
            identity->start_abstime = usage.ri_proc_start_abstime;
            proc_name(pid, identity->name, sizeof(identity->name));
            found = 1;
            break;
        }
        free(threads);
    }
    free(pids);
    return found;
}
