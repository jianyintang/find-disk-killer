#include "CFindDiskKiller.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <libproc.h>
#include <mach/host_info.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/route.h>
#include <stdbool.h>
#include <errno.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <time.h>

#define DM_FILE_EVENT_RING_CAPACITY 512
#define DM_FILE_EVENT_MAX_ROOTS 512

struct DMFSEventWatcher {
    FSEventStreamRef stream;
    dispatch_queue_t queue;
    pthread_mutex_t lock;
    DMFileChangeEvent *events;
    size_t head;
    size_t count;
    int had_gap;
};

static void dm_fsevent_callback(
    ConstFSEventStreamRef stream_ref,
    void *context,
    size_t event_count,
    void *event_paths,
    const FSEventStreamEventFlags event_flags[],
    const FSEventStreamEventId event_ids[]
) {
    (void)stream_ref;
    DMFSEventWatcher *watcher = context;
    if (watcher == NULL || event_paths == NULL) {
        return;
    }
    CFArrayRef paths = (CFArrayRef)event_paths;
    pthread_mutex_lock(&watcher->lock);
    for (size_t index = 0; index < event_count; index++) {
        FSEventStreamEventFlags flags = event_flags[index];
        if ((flags & (kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged)) != 0) {
            watcher->had_gap = 1;
        }

        CFStringRef path = (CFStringRef)CFArrayGetValueAtIndex(paths, (CFIndex)index);
        if (path == NULL || CFGetTypeID(path) != CFStringGetTypeID()) {
            watcher->had_gap = 1;
            continue;
        }
        DMFileChangeEvent event = {0};
        event.event_id = event_ids[index];
        event.flags = flags;
        if (!CFStringGetCString(
            path,
            event.path,
            sizeof(event.path),
            kCFStringEncodingUTF8
        )) {
            watcher->had_gap = 1;
            continue;
        }
        size_t slot;
        if (watcher->count < DM_FILE_EVENT_RING_CAPACITY) {
            slot = (watcher->head + watcher->count) % DM_FILE_EVENT_RING_CAPACITY;
            watcher->count++;
        } else {
            slot = watcher->head;
            watcher->head = (watcher->head + 1) % DM_FILE_EVENT_RING_CAPACITY;
            watcher->had_gap = 1;
        }
        watcher->events[slot] = event;
    }
    pthread_mutex_unlock(&watcher->lock);
}

DMFSEventWatcher *dm_fsevent_watcher_create_paths(
    const char *const root_paths[],
    int path_count
) {
    if (root_paths == NULL || path_count <= 0 || path_count > DM_FILE_EVENT_MAX_ROOTS) {
        return NULL;
    }
    DMFSEventWatcher *watcher = calloc(1, sizeof(DMFSEventWatcher));
    if (watcher == NULL) {
        return NULL;
    }
    watcher->events = calloc(DM_FILE_EVENT_RING_CAPACITY, sizeof(DMFileChangeEvent));
    if (watcher->events == NULL || pthread_mutex_init(&watcher->lock, NULL) != 0) {
        free(watcher->events);
        free(watcher);
        return NULL;
    }

    CFMutableArrayRef paths = CFArrayCreateMutable(
        kCFAllocatorDefault,
        path_count,
        &kCFTypeArrayCallBacks
    );
    if (paths == NULL) {
        dm_fsevent_watcher_destroy(watcher);
        return NULL;
    }
    for (int index = 0; index < path_count; index++) {
        const char *root_path = root_paths[index];
        if (root_path == NULL || root_path[0] != '/') {
            CFRelease(paths);
            dm_fsevent_watcher_destroy(watcher);
            return NULL;
        }
        CFStringRef root = CFStringCreateWithCString(
            kCFAllocatorDefault,
            root_path,
            kCFStringEncodingUTF8
        );
        if (root == NULL) {
            CFRelease(paths);
            dm_fsevent_watcher_destroy(watcher);
            return NULL;
        }
        CFArrayAppendValue(paths, root);
        CFRelease(root);
    }
    FSEventStreamContext context = {0, watcher, NULL, NULL, NULL};
    watcher->stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        dm_fsevent_callback,
        &context,
        paths,
        kFSEventStreamEventIdSinceNow,
        2.0,
        kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
    );
    CFRelease(paths);
    if (watcher->stream == NULL) {
        dm_fsevent_watcher_destroy(watcher);
        return NULL;
    }
    watcher->queue = dispatch_queue_create("com.find-disk-killer.fsevents", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(watcher->stream, watcher->queue);
    return watcher;
}

DMFSEventWatcher *dm_fsevent_watcher_create(const char *root_path) {
    const char *paths[] = {root_path};
    return dm_fsevent_watcher_create_paths(paths, 1);
}

int dm_fsevent_watcher_start(DMFSEventWatcher *watcher) {
    if (watcher == NULL || watcher->stream == NULL) {
        return 0;
    }
    return FSEventStreamStart(watcher->stream) ? 1 : 0;
}

int dm_fsevent_watcher_drain(
    DMFSEventWatcher *watcher,
    DMFileChangeEvent *buffer,
    int capacity,
    int *had_gap
) {
    if (watcher == NULL || buffer == NULL || capacity <= 0) {
        return 0;
    }
    pthread_mutex_lock(&watcher->lock);
    int output_count = (int)(watcher->count < (size_t)capacity
        ? watcher->count
        : (size_t)capacity);
    for (int index = 0; index < output_count; index++) {
        size_t slot = (watcher->head + (size_t)index) % DM_FILE_EVENT_RING_CAPACITY;
        buffer[index] = watcher->events[slot];
    }
    watcher->head = (watcher->head + (size_t)output_count) % DM_FILE_EVENT_RING_CAPACITY;
    watcher->count -= (size_t)output_count;
    if (had_gap != NULL) {
        *had_gap = watcher->had_gap;
    }
    watcher->had_gap = 0;
    pthread_mutex_unlock(&watcher->lock);
    return output_count;
}

void dm_fsevent_watcher_force_gap(DMFSEventWatcher *watcher) {
    if (watcher == NULL) {
        return;
    }
    pthread_mutex_lock(&watcher->lock);
    watcher->had_gap = 1;
    pthread_mutex_unlock(&watcher->lock);
}

void dm_fsevent_watcher_destroy(DMFSEventWatcher *watcher) {
    if (watcher == NULL) {
        return;
    }
    if (watcher->stream != NULL) {
        FSEventStreamStop(watcher->stream);
        FSEventStreamInvalidate(watcher->stream);
        if (watcher->queue != NULL) {
            dispatch_sync(watcher->queue, ^{});
        }
        FSEventStreamRelease(watcher->stream);
    }
    if (watcher->queue != NULL) {
        dispatch_release(watcher->queue);
    }
    pthread_mutex_destroy(&watcher->lock);
    free(watcher->events);
    free(watcher);
}

static uint64_t dm_dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
    if (dictionary == NULL) {
        return 0;
    }

    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }

    int64_t result = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result) || result < 0) {
        return 0;
    }
    return (uint64_t)result;
}

static void dm_copy_registry_name(
    io_registry_entry_t service,
    char *destination,
    size_t capacity,
    uint64_t *media_capacity
) {
    destination[0] = '\0';

    io_registry_entry_t media = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildEntry(service, kIOServicePlane, &media) == KERN_SUCCESS) {
        io_name_t media_name = {0};
        if (IORegistryEntryGetName(media, media_name) == KERN_SUCCESS) {
            snprintf(destination, capacity, "%s", media_name);
        }
        CFTypeRef size_value = IORegistryEntryCreateCFProperty(
            media,
            CFSTR("Size"),
            kCFAllocatorDefault,
            0
        );
        if (size_value != NULL && CFGetTypeID(size_value) == CFNumberGetTypeID()) {
            int64_t size = 0;
            if (CFNumberGetValue((CFNumberRef)size_value, kCFNumberSInt64Type, &size) && size > 0) {
                *media_capacity = (uint64_t)size;
            }
        }
        if (size_value != NULL) {
            CFRelease(size_value);
        }
        IOObjectRelease(media);
    }

    if (destination[0] != '\0') {
        return;
    }

    CFTypeRef product = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        CFSTR("Product Name"),
        kCFAllocatorDefault,
        kIORegistryIterateParents | kIORegistryIterateRecursively
    );

    if (product != NULL && CFGetTypeID(product) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)product, destination, capacity, kCFStringEncodingUTF8);
    }
    if (product != NULL) {
        CFRelease(product);
    }

    if (destination[0] == '\0') {
        io_name_t registry_name = {0};
        if (IORegistryEntryGetName(service, registry_name) == KERN_SUCCESS) {
            snprintf(destination, capacity, "%s", registry_name);
        } else {
            snprintf(destination, capacity, "%s", "Physical storage");
        }
    }
}

static void dm_describe_disk(DMDiskIO *sample) {
    if (sample->bsd_name[0] == '\0') {
        return;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (session == NULL) {
        return;
    }
    DADiskRef disk = DADiskCreateFromBSDName(
        kCFAllocatorDefault,
        session,
        sample->bsd_name
    );
    if (disk == NULL) {
        CFRelease(session);
        return;
    }
    CFDictionaryRef description = DADiskCopyDescription(disk);
    if (description != NULL) {
        sample->is_physical = 0;
        CFTypeRef protocol = CFDictionaryGetValue(
            description,
            kDADiskDescriptionDeviceProtocolKey
        );
        if (protocol != NULL && CFGetTypeID(protocol) == CFStringGetTypeID()) {
            char protocol_name[128] = {0};
            if (CFStringGetCString(
                (CFStringRef)protocol,
                protocol_name,
                sizeof(protocol_name),
                kCFStringEncodingUTF8
            )) {
                sample->is_physical = dm_disk_protocol_is_virtual(protocol_name) ? 0 : 1;
            }
        }
        CFRelease(description);
    }
    CFRelease(disk);
    CFRelease(session);
}

int dm_disk_protocol_is_virtual(const char *protocol_name) {
    if (protocol_name == NULL || protocol_name[0] == '\0') {
        return 1;
    }
    return strcasecmp(protocol_name, "Virtual Interface") == 0
        || strcasecmp(protocol_name, "Disk Image") == 0
        || strcasestr(protocol_name, "virtual") != NULL;
}

int dm_collect_process_io(DMProcessIO *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        return 0;
    }

    int estimated_count = proc_listallpids(NULL, 0);
    if (estimated_count <= 0) {
        return 0;
    }

    int pid_capacity = estimated_count + 256;
    pid_t *pids = calloc((size_t)pid_capacity, sizeof(pid_t));
    if (pids == NULL) {
        return 0;
    }

    int pid_count = proc_listallpids(pids, pid_capacity * (int)sizeof(pid_t));
    if (pid_count <= 0) {
        free(pids);
        return 0;
    }
    int output_count = 0;
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        timebase.numer = 1;
        timebase.denom = 1;
    }

    for (int index = 0; index < pid_count && output_count < capacity; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }

        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
            continue;
        }

        DMProcessIO sample = {0};
        sample.pid = pid;
        sample.start_abstime = usage.ri_proc_start_abstime;
        __uint128_t cpu_ticks = (__uint128_t)usage.ri_user_time + usage.ri_system_time;
        sample.cpu_time_ns = (uint64_t)(
            cpu_ticks * timebase.numer / timebase.denom
        );
        sample.bytes_read = usage.ri_diskio_bytesread;
        sample.bytes_written = usage.ri_diskio_byteswritten;
        sample.resident_memory_bytes = usage.ri_phys_footprint;

        proc_name(pid, sample.name, (uint32_t)sizeof(sample.name));
        if (sample.name[0] == '\0') {
            snprintf(sample.name, sizeof(sample.name), "PID %d", pid);
        }

        buffer[output_count++] = sample;
    }

    free(pids);
    return output_count;
}

int dm_collect_process_path(int32_t pid, char *buffer, int capacity) {
    if (pid <= 0 || buffer == NULL || capacity <= 1) {
        return 0;
    }
    buffer[0] = '\0';
    int count = proc_pidpath(pid, buffer, (uint32_t)capacity);
    if (count <= 0) {
        buffer[0] = '\0';
        return 0;
    }
    buffer[capacity - 1] = '\0';
    return count;
}

static uint64_t dm_elapsed_nanoseconds(struct timespec started) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t seconds = (uint64_t)(now.tv_sec - started.tv_sec);
    int64_t nanoseconds = now.tv_nsec - started.tv_nsec;
    uint64_t elapsed = seconds * 1000000000ULL;
    if (nanoseconds >= 0) {
        return elapsed + (uint64_t)nanoseconds;
    }
    return elapsed - 1000000000ULL + (uint64_t)(nanoseconds + 1000000000LL);
}

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
) {
    if (vnode_count != NULL) {
        *vnode_count = 0;
    }
    if (unreadable_count != NULL) {
        *unreadable_count = 0;
    }
    if (error_code != NULL) {
        *error_code = 0;
    }
    if (budget_exhausted != NULL) {
        *budget_exhausted = 0;
    }
    if (pid <= 0 || buffer == NULL || capacity <= 0) {
        if (error_code != NULL) {
            *error_code = EINVAL;
        }
        return -1;
    }

    struct timespec started = {0};
    clock_gettime(CLOCK_MONOTONIC, &started);

    struct rusage_info_v4 initial_usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&initial_usage) != 0) {
        if (error_code != NULL) {
            *error_code = errno == 0 ? ESRCH : errno;
        }
        return -1;
    }
    if (initial_usage.ri_proc_start_abstime != expected_start_abstime) {
        if (error_code != NULL) {
            *error_code = ESRCH;
        }
        return -1;
    }
    if (maximum_duration_nanoseconds > 0
        && dm_elapsed_nanoseconds(started) >= maximum_duration_nanoseconds) {
        if (budget_exhausted != NULL) {
            *budget_exhausted = 1;
        }
        return 0;
    }

    int required_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required_bytes <= 0) {
        if (error_code != NULL) {
            *error_code = errno == 0 ? EACCES : errno;
        }
        return -1;
    }
    if (maximum_duration_nanoseconds > 0
        && dm_elapsed_nanoseconds(started) >= maximum_duration_nanoseconds) {
        if (budget_exhausted != NULL) {
            *budget_exhausted = 1;
        }
        return 0;
    }

    size_t bounded_bytes = (size_t)capacity * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = calloc((size_t)capacity, sizeof(struct proc_fdinfo));
    if (fds == NULL) {
        if (error_code != NULL) {
            *error_code = ENOMEM;
        }
        return -1;
    }
    int actual_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)bounded_bytes);
    if (actual_bytes <= 0) {
        if (error_code != NULL) {
            *error_code = errno == 0 ? EACCES : errno;
        }
        free(fds);
        return -1;
    }

    int fd_count = actual_bytes / (int)sizeof(struct proc_fdinfo);
    int output_count = 0;
    int observed_vnodes = 0;
    int observed_unreadable = 0;
    if (((size_t)required_bytes > bounded_bytes || (size_t)actual_bytes >= bounded_bytes)
        && budget_exhausted != NULL) {
        *budget_exhausted = 1;
    }
    for (int index = 0; index < fd_count; index++) {
        if (maximum_duration_nanoseconds > 0
            && dm_elapsed_nanoseconds(started) >= maximum_duration_nanoseconds) {
            if (budget_exhausted != NULL) {
                *budget_exhausted = 1;
            }
            break;
        }
        if (fds[index].proc_fdtype != PROX_FDTYPE_VNODE) {
            continue;
        }
        observed_vnodes++;
        if (output_count >= capacity) {
            continue;
        }

        struct vnode_fdinfowithpath details = {0};
        int detail_bytes = proc_pidfdinfo(
            pid,
            fds[index].proc_fd,
            PROC_PIDFDVNODEPATHINFO,
            &details,
            (int)sizeof(details)
        );
        if (maximum_duration_nanoseconds > 0
            && dm_elapsed_nanoseconds(started) >= maximum_duration_nanoseconds
            && budget_exhausted != NULL) {
            *budget_exhausted = 1;
        }
        if (detail_bytes != (int)sizeof(details)) {
            observed_unreadable++;
            continue;
        }

        DMOpenFile sample = {0};
        sample.pid = pid;
        sample.fd = fds[index].proc_fd;
        sample.open_flags = details.pfi.fi_openflags;
        sample.device = details.pvip.vip_vi.vi_stat.vst_dev;
        sample.inode = details.pvip.vip_vi.vi_stat.vst_ino;
        sample.vnode_type = details.pvip.vip_vi.vi_type;
        sample.file_size = details.pvip.vip_vi.vi_stat.vst_size;
        snprintf(sample.path, sizeof(sample.path), "%s", details.pvip.vip_path);
        if (sample.path[0] == '\0') {
            observed_unreadable++;
            continue;
        }
        buffer[output_count++] = sample;
    }
    free(fds);

    struct rusage_info_v4 final_usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&final_usage) != 0
        || final_usage.ri_proc_start_abstime != expected_start_abstime) {
        if (error_code != NULL) {
            *error_code = ESRCH;
        }
        return -1;
    }
    if (maximum_duration_nanoseconds > 0
        && dm_elapsed_nanoseconds(started) >= maximum_duration_nanoseconds
        && budget_exhausted != NULL) {
        *budget_exhausted = 1;
    }

    if (vnode_count != NULL) {
        *vnode_count = observed_vnodes;
    }
    if (unreadable_count != NULL) {
        *unreadable_count = observed_unreadable;
    }
    return output_count;
}

int dm_file_descriptor_kind(
    int32_t pid,
    uint64_t expected_start_abstime,
    int32_t file_descriptor
) {
    if (pid <= 0 || file_descriptor < 0) {
        return -1;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0
        || usage.ri_proc_start_abstime != expected_start_abstime) {
        return -1;
    }

    int required_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required_bytes <= 0) {
        return -1;
    }
    size_t maximum_bytes = 8192 * sizeof(struct proc_fdinfo);
    size_t capacity = (size_t)required_bytes + 32 * sizeof(struct proc_fdinfo);
    if (capacity > maximum_bytes) {
        capacity = maximum_bytes;
    }
    struct proc_fdinfo *fds = calloc(1, capacity);
    if (fds == NULL) {
        return -1;
    }
    int actual_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)capacity);
    if (actual_bytes <= 0) {
        free(fds);
        return -1;
    }

    int result = -1;
    int count = actual_bytes / (int)sizeof(struct proc_fdinfo);
    for (int index = 0; index < count; index++) {
        if (fds[index].proc_fd == file_descriptor) {
            result = fds[index].proc_fdtype == PROX_FDTYPE_VNODE ? 1 : 0;
            break;
        }
    }
    free(fds);

    struct rusage_info_v4 final_usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&final_usage) != 0
        || final_usage.ri_proc_start_abstime != expected_start_abstime) {
        return -1;
    }
    return result;
}

int dm_collect_disk_io(DMDiskIO *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        return 0;
    }

    CFMutableDictionaryRef matching = IOServiceMatching(kIOBlockStorageDriverClass);
    if (matching == NULL) {
        return 0;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (status != KERN_SUCCESS) {
        return 0;
    }

    int output_count = 0;
    io_registry_entry_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL && output_count < capacity) {
        CFTypeRef statistics_value = IORegistryEntryCreateCFProperty(
            service,
            CFSTR(kIOBlockStorageDriverStatisticsKey),
            kCFAllocatorDefault,
            0
        );

        if (statistics_value != NULL && CFGetTypeID(statistics_value) == CFDictionaryGetTypeID()) {
            CFDictionaryRef statistics = (CFDictionaryRef)statistics_value;
            DMDiskIO sample = {0};

            IORegistryEntryGetRegistryEntryID(service, &sample.registry_id);
            sample.bytes_read = dm_dictionary_number(
                statistics,
                CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey)
            );
            sample.bytes_written = dm_dictionary_number(
                statistics,
                CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey)
            );
            sample.read_operations = dm_dictionary_number(
                statistics,
                CFSTR(kIOBlockStorageDriverStatisticsReadsKey)
            );
            sample.write_operations = dm_dictionary_number(
                statistics,
                CFSTR(kIOBlockStorageDriverStatisticsWritesKey)
            );
            dm_copy_registry_name(
                service,
                sample.name,
                sizeof(sample.name),
                &sample.capacity
            );
            io_registry_entry_t media = IO_OBJECT_NULL;
            if (IORegistryEntryGetChildEntry(service, kIOServicePlane, &media) == KERN_SUCCESS) {
                CFTypeRef bsd_name = IORegistryEntryCreateCFProperty(
                    media,
                    CFSTR("BSD Name"),
                    kCFAllocatorDefault,
                    0
                );
                if (bsd_name != NULL && CFGetTypeID(bsd_name) == CFStringGetTypeID()) {
                    CFStringGetCString(
                        (CFStringRef)bsd_name,
                        sample.bsd_name,
                        sizeof(sample.bsd_name),
                        kCFStringEncodingUTF8
                    );
                }
                if (bsd_name != NULL) {
                    CFRelease(bsd_name);
                }
                IOObjectRelease(media);
            }
            dm_describe_disk(&sample);
            bool is_empty_placeholder = sample.bytes_read == 0
                && sample.bytes_written == 0
                && sample.read_operations == 0
                && sample.write_operations == 0
                && strcmp(sample.name, kIOBlockStorageDriverClass) == 0;
            if (!is_empty_placeholder) {
                buffer[output_count++] = sample;
            }
        }

        if (statistics_value != NULL) {
            CFRelease(statistics_value);
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return output_count;
}

int dm_collect_system_stats(DMSystemStats *stats) {
    if (stats == NULL) {
        return 0;
    }
    memset(stats, 0, sizeof(*stats));

    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t cpu_status = host_statistics(
        mach_host_self(),
        HOST_CPU_LOAD_INFO,
        (host_info_t)&cpu,
        &cpu_count
    );
    if (cpu_status == KERN_SUCCESS) {
        stats->cpu_user_ticks = cpu.cpu_ticks[CPU_STATE_USER];
        stats->cpu_system_ticks = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        stats->cpu_nice_ticks = cpu.cpu_ticks[CPU_STATE_NICE];
        stats->cpu_idle_ticks = cpu.cpu_ticks[CPU_STATE_IDLE];
    }

    vm_statistics64_data_t memory = {0};
    mach_msg_type_number_t memory_count = HOST_VM_INFO64_COUNT;
    kern_return_t memory_status = host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        (host_info64_t)&memory,
        &memory_count
    );
    vm_size_t page_size = 0;
    kern_return_t page_status = host_page_size(mach_host_self(), &page_size);
    uint64_t total_memory = 0;
    size_t total_memory_size = sizeof(total_memory);
    int total_status = sysctlbyname(
        "hw.memsize",
        &total_memory,
        &total_memory_size,
        NULL,
        0
    );
    if (memory_status == KERN_SUCCESS
        && page_status == KERN_SUCCESS
        && total_status == 0
        && page_size > 0
        && total_memory > 0) {
        uint64_t page_bytes = (uint64_t)page_size;
        uint64_t available_pages = memory.free_count + memory.speculative_count;
        uint64_t cached_pages = memory.inactive_count;
        uint64_t available_bytes = available_pages * page_bytes;
        if (available_bytes > total_memory) {
            available_bytes = total_memory;
        }
        uint64_t cached_bytes = cached_pages * page_bytes;
        uint64_t remaining_bytes = total_memory - available_bytes;
        if (cached_bytes > remaining_bytes) {
            cached_bytes = remaining_bytes;
        }
        uint64_t used_bytes = total_memory - available_bytes - cached_bytes;
        uint64_t compressed_bytes = memory.compressor_page_count * page_bytes;
        if (compressed_bytes > used_bytes) {
            compressed_bytes = used_bytes;
        }
        stats->memory_total_bytes = total_memory;
        stats->memory_available_bytes = available_bytes;
        stats->memory_cached_bytes = cached_bytes;
        stats->memory_compressed_bytes = compressed_bytes;
        stats->memory_used_bytes = used_bytes;
        stats->memory_stats_available = 1;
    }

    return cpu_status == KERN_SUCCESS;
}

int dm_collect_cpu_core_stats(DMCPUCoreStats *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        return -1;
    }

    natural_t processor_count = 0;
    processor_info_array_t processor_info = NULL;
    mach_msg_type_number_t processor_info_count = 0;
    kern_return_t status = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &processor_count,
        &processor_info,
        &processor_info_count
    );
    if (status != KERN_SUCCESS || processor_info == NULL) {
        return -1;
    }

    int output_count = (int)processor_count;
    if (output_count > capacity) {
        output_count = capacity;
    }
    processor_cpu_load_info_t load = (processor_cpu_load_info_t)processor_info;
    for (int index = 0; index < output_count; index++) {
        buffer[index].index = (uint32_t)index;
        buffer[index].user_ticks = load[index].cpu_ticks[CPU_STATE_USER];
        buffer[index].system_ticks = load[index].cpu_ticks[CPU_STATE_SYSTEM];
        buffer[index].nice_ticks = load[index].cpu_ticks[CPU_STATE_NICE];
        buffer[index].idle_ticks = load[index].cpu_ticks[CPU_STATE_IDLE];
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)processor_info,
        (vm_size_t)processor_info_count * sizeof(integer_t)
    );
    return output_count;
}

int dm_collect_network_interfaces(DMNetworkInterface *output, int capacity) {
    if (output == NULL || capacity <= 0) {
        return -1;
    }

    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0) {
        return -1;
    }

    char *buffer = malloc(length);
    if (buffer == NULL) {
        return -1;
    }
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) {
        free(buffer);
        return -1;
    }

    int output_count = 0;
    char *cursor = buffer;
    char *end = buffer + length;
    while (cursor < end && output_count < capacity) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (header->ifm_msglen == 0) {
            break;
        }
        if (header->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *interface = (struct if_msghdr2 *)cursor;
            bool is_active = (interface->ifm_flags & IFF_UP) != 0;
            bool is_loopback = (interface->ifm_flags & IFF_LOOPBACK) != 0;
            bool is_external_transport = interface->ifm_data.ifi_type == IFT_ETHER
                || interface->ifm_data.ifi_type == IFT_PPP;
            if (is_active && !is_loopback && is_external_transport) {
                DMNetworkInterface sample = {0};
                sample.interface_index = interface->ifm_index;
                sample.bytes_in = interface->ifm_data.ifi_ibytes;
                sample.bytes_out = interface->ifm_data.ifi_obytes;
                if_indextoname(interface->ifm_index, sample.name);
                output[output_count++] = sample;
            }
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return output_count;
}
