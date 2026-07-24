#include "CFindDiskKillerTrace.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/proc_info.h>

#define FDK_TRACE_MAX_PIDS 32768

static int fdk_trace_resolve_thread_from_list(
    uint64_t thread_id,
    const pid_t *pids,
    int pid_count,
    FDKTraceProcessIdentity *identity
) {
    int found = 0;
    for (int index = 0; index < pid_count && !found; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }
        struct proc_threadinfo thread_info = {0};
        int thread_info_bytes = proc_pidinfo(
            pid,
            PROC_PIDTHREADID64INFO,
            thread_id,
            &thread_info,
            (int)sizeof(thread_info)
        );
        if (thread_info_bytes != (int)sizeof(thread_info)) {
            continue;
        }
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(
            pid,
            RUSAGE_INFO_V4,
            (rusage_info_t *)&usage
        ) != 0) {
            continue;
        }
        identity->pid = pid;
        identity->start_abstime = usage.ri_proc_start_abstime;
        proc_name(pid, identity->name, sizeof(identity->name));
        found = 1;
    }
    return found;
}

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

    int found = fdk_trace_resolve_thread_from_list(
        thread_id,
        pids,
        pid_count,
        identity
    );
    free(pids);
    return found;
}

int fdk_trace_resolve_thread_in_processes(
    uint64_t thread_id,
    const int32_t *process_ids,
    int32_t process_count,
    FDKTraceProcessIdentity *identity
) {
    if (thread_id == 0 || process_ids == NULL || process_count <= 0
        || process_count > 64 || identity == NULL) {
        return 0;
    }
    memset(identity, 0, sizeof(*identity));
    pid_t pids[64] = {0};
    for (int32_t index = 0; index < process_count; index++) {
        if (process_ids[index] <= 0) {
            return 0;
        }
        pids[index] = (pid_t)process_ids[index];
    }
    return fdk_trace_resolve_thread_from_list(
        thread_id,
        pids,
        process_count,
        identity
    );
}
