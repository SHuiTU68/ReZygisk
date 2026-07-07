#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

#include "magisk.h"

#include "../constants.h"
#include "../utils.h"
#include "common.h"

#define SBIN_MAGISK LP_SELECT("/sbin/magisk32", "/sbin/magisk64")
#define BITLESS_SBIN_MAGISK "/sbin/magisk"
#define DEBUG_RAMDISK_MAGISK LP_SELECT("/debug_ramdisk/magisk32", "/debug_ramdisk/magisk64")
#define BITLESS_DEBUG_RAMDISK_MAGISK "/debug_ramdisk/magisk"

/* INFO: Longest path */
static char path_to_magisk[sizeof(DEBUG_RAMDISK_MAGISK)] = { 0 };

/* INFO: Cache for denylist results to avoid fork+exec magisk on every app fork.
 * Each entry caches whether a process name is on the denylist. The cache has a
 * TTL to pick up denylist changes made via Magisk app. */
#define DENYLIST_CACHE_TTL_SEC 30
#define DENYLIST_CACHE_SIZE 64

struct denylist_cache_entry {
  char process[PROCESS_NAME_MAX_LEN];
  bool should_umount;
  time_t timestamp;
  bool valid;
};

static struct denylist_cache_entry denylist_cache[DENYLIST_CACHE_SIZE];

static bool denylist_cache_lookup(const char *process, bool *out) {
  time_t now = time(NULL);
  for (size_t i = 0; i < DENYLIST_CACHE_SIZE; i++) {
    if (!denylist_cache[i].valid) continue;
    if (now - denylist_cache[i].timestamp > DENYLIST_CACHE_TTL_SEC) {
      denylist_cache[i].valid = false;
      continue;
    }
    if (strcmp(denylist_cache[i].process, process) == 0) {
      *out = denylist_cache[i].should_umount;
      return true;
    }
  }
  return false;
}

static void denylist_cache_store(const char *process, bool should_umount) {
  /* INFO: Find an empty slot or the oldest entry to replace */
  size_t oldest = 0;
  time_t oldest_time = denylist_cache[0].timestamp;
  for (size_t i = 0; i < DENYLIST_CACHE_SIZE; i++) {
    if (!denylist_cache[i].valid) {
      oldest = i;
      break;
    }
    if (denylist_cache[i].timestamp < oldest_time) {
      oldest_time = denylist_cache[i].timestamp;
      oldest = i;
    }
  }

  denylist_cache[oldest].valid = true;
  denylist_cache[oldest].should_umount = should_umount;
  denylist_cache[oldest].timestamp = time(NULL);
  strncpy(denylist_cache[oldest].process, process, PROCESS_NAME_MAX_LEN - 1);
  denylist_cache[oldest].process[PROCESS_NAME_MAX_LEN - 1] = '\0';
}

/* INFO: Cache for manager uid - the manager package rarely changes, so we
 * cache the result permanently for the lifetime of zygiskd. */
static bool manager_uid_cached = false;
static uid_t cached_manager_uid = (uid_t)-1;

/* INFO: Cache for uid_granted_root to avoid fork+exec(magisk --sqlite) on
 * every app fork. Root grant policy rarely changes, so use a longer TTL. */
#define GRANTED_ROOT_CACHE_TTL_SEC 60
#define GRANTED_ROOT_CACHE_SIZE 64
struct granted_root_cache_entry {
  uid_t uid;
  bool granted;
  time_t timestamp;
  bool valid;
};
static struct granted_root_cache_entry granted_root_cache[GRANTED_ROOT_CACHE_SIZE];

void magisk_get_existence(struct root_impl_state *state) {
  const char *magisk_files[] = {
    SBIN_MAGISK,
    BITLESS_SBIN_MAGISK,
    DEBUG_RAMDISK_MAGISK,
    BITLESS_DEBUG_RAMDISK_MAGISK
  };

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
  /* INFO: Check TTL cache first to avoid fork+exec(magisk --sqlite) on every
   * app fork. Root grant policy rarely changes, so a 60s TTL is safe. */
  time_t now = time(NULL);
  for (size_t i = 0; i < GRANTED_ROOT_CACHE_SIZE; i++) {
    if (!granted_root_cache[i].valid) continue;
    if (now - granted_root_cache[i].timestamp > GRANTED_ROOT_CACHE_TTL_SEC) {
      granted_root_cache[i].valid = false;
      continue;
    }
    if (granted_root_cache[i].uid == uid) {
      return granted_root_cache[i].granted;
    }
  }

  char sqlite_cmd[256];
  snprintf(sqlite_cmd, sizeof(sqlite_cmd), "select 1 from policies where uid=%d and policy=2 limit 1", uid);

  const char *const argv[] = { "magisk", "--sqlite", sqlite_cmd, NULL };

  char result[32];
  if (!exec_command(result, sizeof(result), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  bool granted = result[0] != '\0';

  /* INFO: Store in cache. Find an invalid slot or the oldest entry. */
  size_t oldest = 0;
  time_t oldest_ts = now;
  for (size_t i = 0; i < GRANTED_ROOT_CACHE_SIZE; i++) {
    if (!granted_root_cache[i].valid) {
      oldest = i;
      break;
    }
    if (granted_root_cache[i].timestamp < oldest_ts) {
      oldest_ts = granted_root_cache[i].timestamp;
      oldest = i;
    }
  }
  granted_root_cache[oldest].uid = uid;
  granted_root_cache[oldest].granted = granted;
  granted_root_cache[oldest].timestamp = now;
  granted_root_cache[oldest].valid = true;

  return granted;
}

bool magisk_uid_should_umount(const char *const process) {
  /* INFO: Check cache first to avoid expensive fork+exec on every app fork */
  bool cached_result;
  if (denylist_cache_lookup(process, &cached_result)) {
    return cached_result;
  }

  /* INFO: PROCESS_NAME_MAX_LEN already has a +1 for NULL.
   * Extra space for SQL-quote escaping (worst case: every char is a quote,
   * which doubles to 2 chars) plus surrounding quotes and query overhead. */
  char escaped_process[PROCESS_NAME_MAX_LEN * 2];
  const char *src = process;
  char *dst = escaped_process;
  const char *dst_end = escaped_process + sizeof(escaped_process) - 1;
  /* INFO: Escape double quotes by doubling them to prevent SQL injection.
   * See: https://www.sqlite.org/lang_expr.html#string_literals */
  while (*src && dst < dst_end) {
    if (*src == '"') {
      if (dst + 1 >= dst_end) break;
      *dst++ = '"';
      *dst++ = '"';
      src++;
    } else {
      *dst++ = *src++;
    }
  }
  *dst = '\0';

  char sqlite_cmd[64 + PROCESS_NAME_MAX_LEN * 2];
  /* INFO: Find if process string starts with any data in "process" column */
  snprintf(sqlite_cmd, sizeof(sqlite_cmd), "SELECT 1 FROM denylist WHERE \"%s\" LIKE process || '%%' LIMIT 1", escaped_process);

  const char *const argv[] = { "magisk", "--sqlite", sqlite_cmd, NULL };

  char result[sizeof("1=1")];
  if (!exec_command(result, sizeof(result), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  bool should_umount = result[0] != '\0';
  denylist_cache_store(process, should_umount);

  return should_umount;
}

bool magisk_uid_is_manager(uid_t uid) {
  /* INFO: The manager uid rarely changes - cache it permanently to avoid
   * fork+exec magisk + stat on every app fork. */
  if (manager_uid_cached) {
    return uid == cached_manager_uid;
  }

  const char *const argv[] = { "magisk", "--sqlite", "select value from strings where key=\"requester\" limit 1", NULL };

  char output[128];
  if (!exec_command(output, sizeof(output), (const char *)path_to_magisk, argv)) {
    LOGE("Failed to execute magisk binary: %s", strerror(errno));

    return false;
  }

  char stat_path[PATH_MAX] = "/data/user_de/0/com.topjohnwu.magisk";
  if (output[0] != '\0')
    snprintf(stat_path, sizeof(stat_path), "/data/user_de/0/%s", output + strlen("value="));

  struct stat st;
  if (stat(stat_path, &st) == -1) {
    if (errno != ENOENT) {
      LOGE("Failed to stat %s: %s", stat_path, strerror(errno));
    }

    return false;
  }

  /* INFO: Cache the manager uid for the lifetime of zygiskd */
  cached_manager_uid = st.st_uid;
  manager_uid_cached = true;

  return st.st_uid == uid;
}
