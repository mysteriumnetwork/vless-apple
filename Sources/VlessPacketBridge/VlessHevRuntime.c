// Init/run/cleanup sequence adapted from hev 2.15.0 src/hev-main.c.
// Copyright (c) 2019-2023 hev. MIT License; see NOTICE.
#include "VlessHevRuntime.h"
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
// Tun2SocksKit 5.15.0 ships simulator stubs, not a runnable hev core. Retain
// their existing immediate failure result without referencing private exports.
extern int hev_socks5_tunnel_main_from_str(const unsigned char *, unsigned int, int);
#else
#include "HevPinnedABI.h"
#endif

static void send_quit_locked(struct vless_hev_runtime *runtime)
{
    if (runtime->ready && runtime->stop_requested && !runtime->quit_sent) {
        runtime->quit_sent = true;
        // Successful tunnel_init has created the event socket. Holding this
        // lock prevents tunnel_fini from closing it; one byte cannot fill it.
        // Thus the pinned stop API cannot enter its wait-for-initialization loop.
#if !TARGET_OS_SIMULATOR
        hev_socks5_tunnel_stop();
#endif
    }
}

int vless_hev_runtime_init(struct vless_hev_runtime *runtime)
{
    runtime->ready = runtime->stop_requested = runtime->quit_sent = false;
    return pthread_mutex_init(&runtime->lock, NULL);
}

void vless_hev_runtime_destroy(struct vless_hev_runtime *runtime)
{
    pthread_mutex_destroy(&runtime->lock);
}

void vless_hev_runtime_request_stop(struct vless_hev_runtime *runtime)
{
    pthread_mutex_lock(&runtime->lock);
    runtime->stop_requested = true;
    send_quit_locked(runtime);
    pthread_mutex_unlock(&runtime->lock);
}

int vless_hev_runtime_run(struct vless_hev_runtime *runtime,
                         const unsigned char *config, unsigned int length, int fd)
{
    pthread_mutex_lock(&runtime->lock);
    bool cancelled = runtime->stop_requested;
    pthread_mutex_unlock(&runtime->lock);
    if (cancelled)
        return 0;

#if TARGET_OS_SIMULATOR
    return hev_socks5_tunnel_main_from_str(config, length, fd);
#else
    // Mirror the pinned main's phases instead of guessing that entry into
    // main_from_str means its event descriptor exists. Unwind only phases that
    // succeeded, including failures before tunnel_init can create that socket.
    int result = -1;
    bool logger = false, socks_logger = false, tasks = false;
    if (hev_config_init_from_str(config, length) < 0)
        return -1;
    hev_socks5_set_connect_timeout(hev_config_get_misc_connect_timeout());
    hev_socks5_set_tcp_timeout(hev_config_get_misc_tcp_read_write_timeout());
    hev_socks5_set_udp_timeout(hev_config_get_misc_udp_read_write_timeout());
    hev_socks5_set_udp_recv_buffer_size(hev_config_get_misc_udp_recv_buffer_size());
    int level = hev_config_get_misc_log_level();
    const char *path = hev_config_get_misc_log_file();
    result = -2;
    if (hev_logger_init(level, path) < 0)
        goto cleanup;
    logger = true;
    result = -3;
    if (hev_socks5_logger_init(level, path) < 0)
        goto cleanup;
    socks_logger = true;
    (void)set_limit_nofile(hev_config_get_misc_limit_nofile());
    const char *pid_file = hev_config_get_misc_pid_file();
    if (pid_file)
        run_as_daemon(pid_file);
    result = -4;
    if (hev_task_system_init() < 0)
        goto cleanup;
    tasks = true;
    lwip_init();
    result = -5;
    // The pinned init unwinds its own partial tunnel state on failure.
    if (hev_socks5_tunnel_init(fd) < 0)
        goto cleanup;

    pthread_mutex_lock(&runtime->lock);
    runtime->ready = true;
    send_quit_locked(runtime); // Only if a stop was queued while initializing.
    pthread_mutex_unlock(&runtime->lock);
    result = hev_socks5_tunnel_run();
    pthread_mutex_lock(&runtime->lock);
    runtime->ready = false;
    hev_socks5_tunnel_fini();
    pthread_mutex_unlock(&runtime->lock);

cleanup:
    if (socks_logger)
        hev_socks5_logger_fini();
    if (logger)
        hev_logger_fini();
    hev_config_fini();
    if (tasks)
        hev_task_system_fini();
    return result;
#endif
}
