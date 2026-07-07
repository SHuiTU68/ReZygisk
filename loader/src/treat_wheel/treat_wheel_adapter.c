#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <jni.h>

#include "../treat_wheel/utils.h"
#include "../treat_wheel/hiding.h"
#include "../treat_wheel/zygisk.h"
#include "treat_wheel_adapter.h"

/* INFO: Companion fd placeholder. The original Treat-Wheel module defined this
 * for ReVanced mounts umount and custom font loading, which are removed from
 * this build. Defined here to satisfy the linker for the unused functions in
 * hiding.c that still reference it. */
int cfd = -1;

/* INFO: State path inside ReZygisk directory. Use a non-obvious name to avoid
 * leaving detectable traces (the previous "tw_state" name was a clear marker
 * that Treat Wheel was integrated). */
#define TW_STATE_PATH "/data/adb/rezygisk/.rz_cfg"

static struct tw_module_state g_tw_state = { 0 };
static bool g_tw_initialized = false;
/* INFO: Cached mtime of tw_state to avoid re-reading the file on every app
 * fork. Only re-parse when the file has actually been modified by WebUI. */
static time_t g_tw_state_mtime = 0;
static bool g_tw_state_loaded = false;
/* INFO: stat() TTL to avoid a stat syscall on every single app fork. The
 * state file only changes when WebUI writes to it, so a short TTL is safe. */
#define TW_STATE_STAT_TTL_SEC 5
static time_t g_tw_last_stat_time = 0;

static void tw_load_state(void) {
  /* INFO: Skip stat() entirely if we checked recently and the file was loaded.
   * This avoids one stat syscall per app fork on the hot path. */
  time_t now = time(NULL);
  if (g_tw_state_loaded && g_tw_last_stat_time != 0 && (now - g_tw_last_stat_time) < TW_STATE_STAT_TTL_SEC) {
    return;
  }
  g_tw_last_stat_time = now;

  struct stat st;
  if (stat(TW_STATE_PATH, &st) == 0) {
    /* INFO: Skip re-parsing if the file hasn't changed since last read */
    if (g_tw_state_loaded && st.st_mtime == g_tw_state_mtime) {
      return;
    }
    g_tw_state_mtime = st.st_mtime;
  } else {
    /* INFO: File doesn't exist - reset to safe defaults */
    memset(&g_tw_state, 0, sizeof(g_tw_state));
    g_tw_state_loaded = true;
    return;
  }

  FILE *fp = fopen(TW_STATE_PATH, "r");
  if (!fp) {
    memset(&g_tw_state, 0, sizeof(g_tw_state));
    g_tw_state_loaded = true;
    return;
  }

  /* INFO: Reset state before parsing */
  memset(&g_tw_state, 0, sizeof(g_tw_state));

  char line[256];
  while (fgets(line, sizeof(line), fp)) {
    if (tw_str_starts_with(line, "ignoring=")) {
      g_tw_state.is_ignoring = strncmp(line + strlen("ignoring="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_prop_spoofing=")) {
      g_tw_state.disable_prop_spoofing = strncmp(line + strlen("disable_prop_spoofing="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_gsi_hiding=")) {
      g_tw_state.disable_gsi_hiding = strncmp(line + strlen("disable_gsi_hiding="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_zygote_mountinfo_leak_fixing=")) {
      g_tw_state.disable_zygote_mountinfo_leak_fixing = strncmp(line + strlen("disable_zygote_mountinfo_leak_fixing="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_maps_hiding=")) {
      g_tw_state.disable_maps_hiding = strncmp(line + strlen("disable_maps_hiding="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_revanced_mounts_umount=")) {
      g_tw_state.disable_revanced_mounts_umount = strncmp(line + strlen("disable_revanced_mounts_umount="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_custom_font_loading=")) {
      g_tw_state.disable_custom_font_loading = strncmp(line + strlen("disable_custom_font_loading="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_denylist_logic_inversion=")) {
      g_tw_state.disable_denylist_logic_inversion = strncmp(line + strlen("disable_denylist_logic_inversion="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_module_loading_traces_hiding=")) {
      g_tw_state.disable_module_loading_traces_hiding = strncmp(line + strlen("disable_module_loading_traces_hiding="), "true", 4) == 0;
    } else if (tw_str_starts_with(line, "disable_frida_traces_hiding=")) {
      g_tw_state.disable_frida_traces_hiding = strncmp(line + strlen("disable_frida_traces_hiding="), "true", 4) == 0;
    }
  }

  fclose(fp);
  g_tw_state_loaded = true;
}

void tw_adapter_init(void) {
  if (g_tw_initialized) return;

  tw_load_state();

  if (g_tw_state.is_ignoring) {
    LOGI("Treat Wheel: ignoring mode, skipping init.");
    g_tw_initialized = true;
    return;
  }

  if (!tw_do_preinitialize()) {
    LOGE("Treat Wheel: preinitialize failed.");
    g_tw_state.is_ignoring = true;
    g_tw_initialized = true;
    return;
  }

  g_tw_initialized = true;
  LOGI("Treat Wheel: initialized.");
}

void tw_adapter_pre_specialize(JNIEnv *env, const char *process_name, uint32_t flags) {
  (void) env;
  (void) process_name;

  if (!g_tw_initialized) {
    tw_adapter_init();
  }

  if (g_tw_state.is_ignoring) return;

  /* INFO: Reload state only if the file has been modified (mtime check) */
  tw_load_state();
  if (g_tw_state.is_ignoring) return;

  bool on_denylist = (flags & PROCESS_ON_DENYLIST) == PROCESS_ON_DENYLIST;

  /* INFO: ReZygisk already handles mount namespace switching correctly at
   * hook.c (Clean for denylist, Mounted for others). We must NOT call
   * tw_do_denylist_logic_inversion here because it would REVERT the mount
   * namespace (switching denylist apps back to Mounted), causing mount
   * points to be re-mounted after ReZygisk just unmounted them.
   *
   * The "denylist logic inversion" toggle in WebUI now only controls
   * whether hiding features are applied to denylist apps. It no longer
   * inverts the mount namespace. */

  if (on_denylist) {
    LOGI("Treat Wheel: process is on denylist, running hiding.");

    /* INFO: Skip GSI hiding as requested by user */
    (void)g_tw_state.disable_gsi_hiding;

    if (!g_tw_state.disable_zygote_mountinfo_leak_fixing) {
      tw_do_zygote_mountinfo_leak_hiding(NULL, env);
    }
    if (!g_tw_state.disable_maps_hiding) {
      tw_do_maps_hiding(NULL, env);
    }
    if (!g_tw_state.disable_frida_traces_hiding) {
      tw_do_frida_hiding(NULL, env);
    }
  }
}

void tw_adapter_atexit_cleanup(JNIEnv *env, uint32_t flags) {
  if (g_tw_state.is_ignoring) return;

  bool on_denylist = (flags & PROCESS_ON_DENYLIST) == PROCESS_ON_DENYLIST;

  /* INFO: Apply atexit hiding for denylist processes */
  if (on_denylist && !g_tw_state.disable_module_loading_traces_hiding) {
    tw_do_atexit_hiding(NULL, env);
  }

  tw_do_deinitialize();
}

bool tw_adapter_is_enabled(const char *feature) {
  if (!feature) return false;

  if (strcmp(feature, "ignoring") == 0) return g_tw_state.is_ignoring;
  if (strcmp(feature, "prop_spoofing") == 0) return !g_tw_state.disable_prop_spoofing;
  if (strcmp(feature, "gsi_hiding") == 0) return !g_tw_state.disable_gsi_hiding;
  if (strcmp(feature, "zygote_mountinfo_leak_fixing") == 0) return !g_tw_state.disable_zygote_mountinfo_leak_fixing;
  if (strcmp(feature, "maps_hiding") == 0) return !g_tw_state.disable_maps_hiding;
  if (strcmp(feature, "denylist_logic_inversion") == 0) return !g_tw_state.disable_denylist_logic_inversion;
  if (strcmp(feature, "module_loading_traces_hiding") == 0) return !g_tw_state.disable_module_loading_traces_hiding;
  if (strcmp(feature, "frida_traces_hiding") == 0) return !g_tw_state.disable_frida_traces_hiding;

  return false;
}
