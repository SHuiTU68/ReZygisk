#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <sys/stat.h>
#include <unistd.h>

#include "../constants.h"
#include "../utils.h"
#include "common.h"

#include "apatch.h"

void apatch_get_existence(struct root_impl_state *state) {
  if (access("/data/adb/ap/bin/apd", F_OK) != 0) {
    state->state = Inexistent;

    return;
  }

  const char *PATH = getenv("PATH");
  if (PATH == NULL) {
    LOGE("Failed to get PATH environment variable");

    state->state = Inexistent;

    return;
  }

  if (strstr(PATH, "/data/adb/ap/bin") == NULL) {
    LOGE("APatch's APD binary is not in PATH");

    state->state = Inexistent;

    return;
  }

  char apatch_version[32] = { 0 };
  const char *const argv[] = { "apd", "-V", NULL };

  if (!exec_command(apatch_version, sizeof(apatch_version), "/data/adb/apd", argv)) {
    LOGE("Failed to execute apd binary: %s", strerror(errno));

    state->state = Inexistent;

    return;
  }

  /* INFO: Verify the output starts with "apd " prefix before offsetting.
   * exec_command can return true with an empty/short buffer on read failure,
   * which would cause atoi() to read uninitialized stack memory. */
  static const char apd_prefix[] = "apd ";
  size_t prefix_len = sizeof(apd_prefix) - 1;
  if (strlen(apatch_version) < prefix_len ||
      strncmp(apatch_version, apd_prefix, prefix_len) != 0) {
    LOGE("Unexpected apd output: \"%s\"", apatch_version);

    state->state = Abnormal;

    return;
  }

  int version = atoi(apatch_version + prefix_len);

  if (version == 0) state->state = Abnormal;
  else if (version >= MIN_APATCH_VERSION && version <= 999999) state->state = Supported;
  else if (version >= 1 && version <= MIN_APATCH_VERSION - 1) state->state = TooOld;
  else state->state = Abnormal;
}

struct package_config {
  char *process;
  uid_t uid;
  bool root_granted;
  bool umount_needed;
};

struct packages_config {
  struct package_config *configs;
  size_t size;
};

void _apatch_free_package_config(struct packages_config *restrict config) {
  for (size_t i = 0; i < config->size; i++) {
    free(config->configs[i].process);
  }

  free(config->configs);
}

/* WARNING: Dynamic memory based */
bool _apatch_get_package_config(struct packages_config *restrict config) {
  config->configs = NULL;
  config->size = 0;

  FILE *fp = fopen("/data/adb/ap/package_config", "r");
  if (fp == NULL) {
    LOGE("Failed to open APatch's package_config: %s", strerror(errno));

    return false;
  }

  char line[1024];
  /* INFO: Skip the CSV header */
  if (fgets(line, sizeof(line), fp) == NULL) {
    LOGE("Failed to read APatch's package_config header: %s", strerror(errno));

    fclose(fp);

    return false;
  }

  while (fgets(line, sizeof(line), fp) != NULL) {
    struct package_config *tmp_configs = realloc(config->configs, (config->size + 1) * sizeof(struct package_config));
    if (tmp_configs == NULL) {
      LOGE("Failed to realloc APatch config struct: %s", strerror(errno));

      _apatch_free_package_config(config);
      fclose(fp);

      return false;
    }
    config->configs = tmp_configs;

    char *save_ptr = NULL;
    const char *process_str = strtok_r(line, ",", &save_ptr);
    if (process_str == NULL) continue;

    const char *exclude_str = strtok_r(NULL, ",", &save_ptr);
    if (exclude_str == NULL) continue;

    const char *allow_str = strtok_r(NULL, ",", &save_ptr);
    if (allow_str == NULL) continue;

    const char *uid_str = strtok_r(NULL, ",", &save_ptr);
    if (uid_str == NULL) continue;

    config->configs[config->size].process = strdup(process_str);
    if (config->configs[config->size].process == NULL) {
      LOGE("Failed to strdup for the process \"%s\": %s", process_str, strerror(errno));

      _apatch_free_package_config(config);
      fclose(fp);

      return false;
    }
    config->configs[config->size].uid = (uid_t)atoi(uid_str);
    config->configs[config->size].root_granted = strcmp(allow_str, "1") == 0;
    config->configs[config->size].umount_needed = strcmp(exclude_str, "1") == 0;

    config->size++;
  }

  fclose(fp);

  return true;
}

bool apatch_uid_granted_root(uid_t uid) {
  struct packages_config config;
  if (!_apatch_get_package_config(&config)) return false;

  for (size_t i = 0; i < config.size; i++) {
    if (config.configs[i].uid != uid) continue;

    /* INFO: This allow us to copy the information to avoid use-after-free */
    bool root_granted = config.configs[i].root_granted;

    _apatch_free_package_config(&config);

    return root_granted;
  }

  _apatch_free_package_config(&config);

  return false;
}

bool apatch_uid_should_umount(uid_t uid, const char *const process) {
  struct packages_config config;
  if (!_apatch_get_package_config(&config)) return false;

  for (size_t i = 0; i < config.size; i++) {
    if (config.configs[i].uid != uid) continue;

    /* INFO: This allow us to copy the information to avoid use-after-free */
    bool umount_needed = config.configs[i].umount_needed;

    _apatch_free_package_config(&config);

    return umount_needed;
  }

  /* INFO: Isolated services have different UIDs than the main app, and
             while libzygisk.so has code to send the UID of the app related
             to the isolated service, we add this so that in case it fails,
             this should avoid it pass through as Mounted.
  */
  if (IS_ISOLATED_SERVICE(uid)) {
    size_t targeted_process_length = strlen(process);

    for (size_t i = 0; i < config.size; i++) {
      size_t config_process_length = strlen(config.configs[i].process);

      /* INFO: Match the config process name as a prefix of the target process
       * name, and verify the next character is ':' (isolated service suffix
       * separator) or '\0' (exact match). Using the shorter length as the
       * comparison bound (previous behavior) was too permissive: a config
       * entry "com" would match "com.evil:isolated", and "com.app" would
       * match "com.apple:isolated". */
      if (targeted_process_length < config_process_length) continue;
      if (strncmp(process, config.configs[i].process, config_process_length) != 0) continue;

      char next_char = process[config_process_length];
      if (next_char != ':' && next_char != '\0') continue;

      /* INFO: This allow us to copy the information to avoid use-after-free */
      bool umount_needed = config.configs[i].umount_needed;

      _apatch_free_package_config(&config);

      return umount_needed;
    }
  }

  _apatch_free_package_config(&config);

  return false;
}

/* INFO: Cache for APatch manager uid - the manager package rarely changes,
 * so we cache the result permanently to avoid a stat() syscall per app fork. */
static bool apatch_manager_uid_cached = false;
static uid_t apatch_cached_manager_uid = (uid_t)-1;

bool apatch_uid_is_manager(uid_t uid) {
  if (!apatch_manager_uid_cached) {
    struct stat st;
    if (stat("/data/user_de/0/me.bmax.apatch", &st) == -1) {
      if (errno != ENOENT) {
        LOGE("Failed to stat APatch manager data directory: %s", strerror(errno));
      }

      /* INFO: Cache the "not found" result too, but allow retry by not
       * setting apatch_manager_uid_cached if it's ENOENT (manager not
       * installed yet). Only cache permanent failures. */
      if (errno == ENOENT) {
        apatch_cached_manager_uid = (uid_t)-1;
        apatch_manager_uid_cached = true;
      }

      return false;
    }

    apatch_cached_manager_uid = st.st_uid;
    apatch_manager_uid_cached = true;
  }

  if (apatch_cached_manager_uid == (uid_t)-1) return false;

  return uid == apatch_cached_manager_uid;
}
