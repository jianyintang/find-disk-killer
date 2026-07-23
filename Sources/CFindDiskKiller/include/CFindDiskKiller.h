#ifndef CFINDDISKKILLER_H
#define CFINDDISKKILLER_H

#include <stdint.h>

#define DM_PROCESS_NAME_MAX 256
#define DM_PROCESS_PATH_MAX 4096
#define DM_DISK_NAME_MAX 256
#define DM_BSD_NAME_MAX 64
#define DM_INTERFACE_NAME_MAX 64
#define DM_OPEN_FILE_PATH_MAX 1024
#define DM_FILE_EVENT_PATH_MAX 1024

typedef struct {
    int32_t pid;
    uint64_t start_abstime;
    uint64_t cpu_time_ns;
    uint64_t bytes_read;
    uint64_t bytes_written;
    char name[DM_PROCESS_NAME_MAX];
    char path[DM_PROCESS_PATH_MAX];
} DMProcessIO;

typedef struct {
    uint64_t registry_id;
    uint64_t bytes_read;
    uint64_t bytes_written;
    uint64_t read_operations;
    uint64_t write_operations;
    uint64_t capacity;
    uint8_t is_physical;
    char name[DM_DISK_NAME_MAX];
    char bsd_name[DM_BSD_NAME_MAX];
} DMDiskIO;

typedef struct {
    uint64_t cpu_user_ticks;
    uint64_t cpu_system_ticks;
    uint64_t cpu_nice_ticks;
    uint64_t cpu_idle_ticks;
} DMSystemStats;

typedef struct {
    uint32_t interface_index;
    uint64_t bytes_in;
    uint64_t bytes_out;
    char name[DM_INTERFACE_NAME_MAX];
} DMNetworkInterface;

typedef struct {
    int32_t pid;
    int32_t fd;
    uint32_t open_flags;
    uint32_t device;
    uint64_t inode;
    int32_t vnode_type;
    int64_t file_size;
    char path[DM_OPEN_FILE_PATH_MAX];
} DMOpenFile;

typedef struct {
    uint64_t event_id;
    uint64_t flags;
    char path[DM_FILE_EVENT_PATH_MAX];
} DMFileChangeEvent;

typedef struct DMFSEventWatcher DMFSEventWatcher;

int dm_collect_process_io(DMProcessIO *buffer, int capacity);
int dm_collect_disk_io(DMDiskIO *buffer, int capacity);
int dm_collect_system_stats(DMSystemStats *stats);
int dm_collect_network_interfaces(DMNetworkInterface *buffer, int capacity);
int dm_disk_protocol_is_virtual(const char *protocol_name);
int dm_collect_open_files(
    int32_t pid,
    uint64_t expected_start_abstime,
    DMOpenFile *buffer,
    int capacity,
    uint64_t maximum_duration_nanoseconds,
    int *vnode_count,
    int *unreadable_count,
    int *budget_exhausted,
    int *error_code
);
DMFSEventWatcher *dm_fsevent_watcher_create(const char *root_path);
int dm_fsevent_watcher_start(DMFSEventWatcher *watcher);
int dm_fsevent_watcher_drain(
    DMFSEventWatcher *watcher,
    DMFileChangeEvent *buffer,
    int capacity,
    int *had_gap
);
void dm_fsevent_watcher_force_gap(DMFSEventWatcher *watcher);
void dm_fsevent_watcher_destroy(DMFSEventWatcher *watcher);

#endif
