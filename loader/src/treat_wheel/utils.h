#ifndef TW_UTILS_H
#define TW_UTILS_H

#include <stdbool.h>

#include <android/log.h>

#include "daemon.h"

#ifdef DEBUG
  #define LOGD(...) do { __android_log_print(ANDROID_LOG_DEBUG, "ReZygisk-TW", __VA_ARGS__); } while (0)
  #define LOGI(...) do { __android_log_print(ANDROID_LOG_INFO, "ReZygisk-TW", __VA_ARGS__); } while (0)
  #define LOGW(...) do { __android_log_print(ANDROID_LOG_WARN, "ReZygisk-TW", __VA_ARGS__); } while (0)
  #define LOGE(...) do { __android_log_print(ANDROID_LOG_ERROR, "ReZygisk-TW", __VA_ARGS__); } while (0)
  #define LOGF(...) do { __android_log_print(ANDROID_LOG_FATAL, "ReZygisk-TW", __VA_ARGS__); } while (0)
  #define PLOGE(msg, ...) do { __android_log_print(ANDROID_LOG_ERROR, "ReZygisk-TW", "%s: " msg ": %s", __func__, ##__VA_ARGS__, strerror(errno)); } while (0)
#else
  #define LOGD(...)
  #define LOGI(...)
  #define LOGW(...)
  #define LOGE(...)
  #define LOGF(...)
  #define PLOGE(msg, ...)
#endif

struct tw_map {
  uintptr_t addr_start;
  uintptr_t addr_end;
  uintptr_t addr_offset;
  uint8_t perms;
  bool is_private;
  dev_t dev;
  ino_t inode;
  char *path;
};

struct tw_maps {
  struct tw_map *maps;
  size_t size;
};

struct tw_mountinfo {
  unsigned int id;
  unsigned int parent;
  dev_t device;
  char *root;
  char *target;
  char *vfs_option;
  struct {
    unsigned int shared;
    unsigned int master;
    unsigned int propagate_from;
  } optional;
  char *type;
  char *source;
  char *fs_option;
};

struct tw_mountsinfo {
  struct tw_mountinfo *mounts;
  size_t size;
};

enum daemon_operations {
  DAEMON_CHECK_IGNORING,
  DAEMON_CHECK_FONTS,
  DAEMON_CHECK_POINT,
  DAEMON_GET_RVX_MOUNTS,
  DAEMON_GOODBYE
};

enum module_status {
  MODULE_STATUS_INJECTED,
  MODULE_STATUS_MIDPERFORMING,
  MODULE_STATUS_HIDING
};

struct tw_module_state {
  bool is_ignoring;
  bool disable_prop_spoofing;
  bool disable_gsi_hiding;
  bool disable_zygote_mountinfo_leak_fixing;
  bool disable_maps_hiding;
  bool disable_revanced_mounts_umount;
  bool disable_custom_font_loading;
  bool disable_denylist_logic_inversion;
  bool disable_module_loading_traces_hiding;
  bool disable_frida_traces_hiding;
};

bool tw_str_starts_with(const char *str, const char *needle);

bool tw_str_ends_with(const char *str, const char *needle);

bool tw_str_equal(const char *str1, const char *str2);

void tw_free_maps(struct tw_maps *maps);

struct tw_maps *tw_parse_maps(const char *filename);

struct tw_mountsinfo *tw_parse_mountinfo(const char *filename);

void tw_free_mountsinfo(struct tw_mountsinfo *mounts);

bool tw_switch_mount_namespace(pid_t pid);

ssize_t tw_write_fd(int fd, int sendfd);

int tw_read_fd(int fd);

ssize_t tw_write_loop(int fd, const void *buf, size_t count);

ssize_t tw_read_loop(int fd, void *buf, size_t count);

#define tw_write_func_def(type)              \
  ssize_t tw_write_## type(int fd, type val)

#define tw_read_func_def(type)               \
  ssize_t tw_read_## type(int fd, type *val)

tw_write_func_def(size_t);
tw_read_func_def(size_t);

tw_write_func_def(uint32_t);
tw_read_func_def(uint32_t);

tw_write_func_def(uint8_t);
tw_read_func_def(uint8_t);

time_t tw_mono_sec_now(void);

#ifndef UTILS_NO_SSL
  int verify_eddsa(unsigned char *to_verify, size_t to_verify_len, unsigned char *public_key, size_t public_key_len, unsigned char *signature, size_t signature_len);

  int hash_file(char *file, unsigned char **to_verify, size_t *to_verify_size);

  unsigned char *verify_rezygisk(char **files, size_t files_length, size_t *to_verify_size);
#endif

#ifdef IS_ZYGISK_LIB
  bool tw_update_mnt_ns(enum mount_namespace_state mns_state);
#endif

#endif /* TW_UTILS_H */
