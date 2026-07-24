#ifndef CFINDDISKKILLERTRACE_H
#define CFINDDISKKILLERTRACE_H

#include <stdint.h>

#define FDK_TRACE_PROCESS_NAME_MAX 256

typedef struct {
    int32_t pid;
    uint64_t start_abstime;
    char name[FDK_TRACE_PROCESS_NAME_MAX];
} FDKTraceProcessIdentity;

int fdk_trace_resolve_thread(
    uint64_t thread_id,
    FDKTraceProcessIdentity *identity
);

#endif
