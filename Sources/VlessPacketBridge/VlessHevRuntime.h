#ifndef VLESS_HEV_RUNTIME_H
#define VLESS_HEV_RUNTIME_H

#include <pthread.h>
#include <stdbool.h>

// One runtime belongs to one bridge. Its lock protects hev's quit descriptor
// from publication until destruction. The bridge serializes process-wide runs.
struct vless_hev_runtime {
    pthread_mutex_t lock;
    bool ready;
    bool stop_requested;
    bool quit_sent;
};

int vless_hev_runtime_init(struct vless_hev_runtime *runtime);
void vless_hev_runtime_destroy(struct vless_hev_runtime *runtime);
int vless_hev_runtime_run(struct vless_hev_runtime *runtime,
                         const unsigned char *config, unsigned int length, int fd);
// Before init: queue the request. After successful init: send once. After
// cleanup: do nothing. Never wait for initialization on the caller's thread.
void vless_hev_runtime_request_stop(struct vless_hev_runtime *runtime);

#endif
