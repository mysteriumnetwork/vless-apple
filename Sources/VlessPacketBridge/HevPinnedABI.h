#ifndef VLESS_HEV_PINNED_ABI_H
#define VLESS_HEV_PINNED_ABI_H

// Private exports of hev 2.15.0, shipped by Tun2SocksKit 5.15.0. These are not
// part of its public umbrella header. Keep signatures and the init/cleanup
// sequence in sync with that exact archive when changing the package pin.
extern int hev_config_init_from_str(const unsigned char *, unsigned int);
extern void hev_config_fini(void);
extern int hev_config_get_misc_connect_timeout(void);
extern int hev_config_get_misc_tcp_read_write_timeout(void);
extern int hev_config_get_misc_udp_read_write_timeout(void);
extern int hev_config_get_misc_udp_recv_buffer_size(void);
extern int hev_config_get_misc_log_level(void);
extern const char *hev_config_get_misc_log_file(void);
extern int hev_config_get_misc_limit_nofile(void);
extern const char *hev_config_get_misc_pid_file(void);
extern void hev_socks5_set_connect_timeout(int);
extern void hev_socks5_set_tcp_timeout(int);
extern void hev_socks5_set_udp_timeout(int);
extern void hev_socks5_set_udp_recv_buffer_size(int);
// The upstream logger-level enums use the C int ABI.
extern int hev_logger_init(int, const char *);
extern void hev_logger_fini(void);
extern int hev_socks5_logger_init(int, const char *);
extern void hev_socks5_logger_fini(void);
extern int set_limit_nofile(int);
extern void run_as_daemon(const char *);
extern int hev_task_system_init(void);
extern void hev_task_system_fini(void);
extern void lwip_init(void);
extern int hev_socks5_tunnel_init(int);
extern int hev_socks5_tunnel_run(void);
extern void hev_socks5_tunnel_fini(void);
extern void hev_socks5_tunnel_stop(void);

#endif
