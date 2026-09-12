#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

#include "magisk.h"

#include "../utils.h"
#include "common.h"

#define SBIN_MAGISK LP_SELECT("/sbin/magisk32", "/sbin/magisk64")
#define BITLESS_SBIN_MAGISK "/sbin/magisk"
#define DEBUG_RAMDISK_MAGISK LP_SELECT("/debug_ramdisk/magisk32", "/debug_ramdisk/magisk64")
#define BITLESS_DEBUG_RAMDISK_MAGISK "/debug_ramdisk/magisk"

/* INFO: Longest path */
static char path_to_magisk[sizeof(DEBUG_RAMDISK_MAGISK)] = { 0 };

/* INFO: Data directories of the manager application, indexed by Magisk
           variant: the official Magisk uses "com.topjohnwu.magisk", while
           the Alpha branch (vvb2060) uses "io.github.vvb2060.magisk". */
static const char *magisk_manager_paths[] = {
  "/data/user_de/0/com.topjohnwu.magisk",
  "/data/user_de/0/io.github.vvb2060.magisk"
};

void magisk_get_existence(struct root_impl_state *state) {
  const char *magisk_files[] = {
    SBIN_MAGISK,
    BITLESS_SBIN_MAGISK,
    DEBUG_RAMDISK_MAGISK,
    BITLESS_DEBUG_RAMDISK_MAGISK
  };

  /* INFO: Both Magisk variants share the same binaries and database, differing
             only in the manager package name, so the existence of the manager
             data directory is used to tell them apart. */
  state->variant = MOfficial;
  if (access(magisk_manager_paths[MAlpha], F_OK) == 0) state->variant = MAlpha;

  for (size_t i = 0; i < sizeof(magisk_files) / sizeof(magisk_files[0]); i++) {
    if (access(magisk_files[i], F_OK) != 0) continue;

    strcpy(path_to_magisk, magisk_files[i]);

    break;
  }

  if (path_to_magisk[0] == '\0') {
    state->state = Inexistent;

    return;
  }

  const char *argv[] = { "magisk", "-V", NULL };

  char magisk_version[32];
  if (!exec_command(magisk_version, sizeof(magisk_version), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    state->state = Abnormal;

    return;
  }

  if (atoi(magisk_version) >= MIN_MAGISK_VERSION) state->state = Supported;
  else state->state = TooOld;
}

bool magisk_uid_granted_root(uid_t uid) {
  char sqlite_cmd[256];
  snprintf(sqlite_cmd, sizeof(sqlite_cmd), "select 1 from policies where uid=%d and policy=2 limit 1", uid);

  const char *const argv[] = { "magisk", "--sqlite", sqlite_cmd, NULL };

  char result[32];
  if (!exec_command(result, sizeof(result), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  return result[0] != '\0';
}

bool magisk_uid_should_umount(const char *const process) {
  /* INFO: PROCESS_NAME_MAX_LEN already has a +1 for NULL */
  char sqlite_cmd[59 + PROCESS_NAME_MAX_LEN];
  /* INFO: Find if process string starts with any data in "process" column */
  snprintf(sqlite_cmd, sizeof(sqlite_cmd), "SELECT 1 FROM denylist WHERE \"%s\" LIKE process || '%%' LIMIT 1", process);

  const char *const argv[] = { "magisk", "--sqlite", sqlite_cmd, NULL };

  char result[sizeof("1=1")];
  if (!exec_command(result, sizeof(result), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  return result[0] != '\0';
}

bool magisk_uid_is_manager(uid_t uid) {
  bool known_manager_found = false;

  /* INFO: The known manager data directories are probed first, as they cover
             the vast majority of devices, avoiding the expensive execution
             of the magisk binary. */
  for (size_t i = 0; i < sizeof(magisk_manager_paths) / sizeof(magisk_manager_paths[0]); i++) {
    struct stat st;
    if (stat(magisk_manager_paths[i], &st) == -1) continue;

    if (st.st_uid == uid) return true;

    known_manager_found = true;
  }

  /* INFO: When a known manager exists, the manager is necessarily one of
             them, so the UID belongs to something else. */
  if (known_manager_found) return false;

  /* INFO: Otherwise, the manager may use a spoofed or custom package name,
             so fall back to the requester string stored in the Magisk
             database. */
  const char *const argv[] = { "magisk", "--sqlite", "select value from strings where key=\"requester\" limit 1", NULL };

  char output[128];
  if (!exec_command(output, sizeof(output), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  if (output[0] == '\0') return false;

  /* INFO: The sqlite wrapper outputs "value=<requester>", where <requester>
             is the package name of the manager application. */
  char stat_path[PATH_MAX];
  snprintf(stat_path, sizeof(stat_path), "/data/user_de/0/%s", output + strlen("value="));

  struct stat st;
  return stat(stat_path, &st) == 0 && st.st_uid == uid;
}
