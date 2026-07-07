#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <jni.h>

#include "../treat_wheel/utils.h"
#include "../treat_wheel/hiding.h"
#include "../treat_wheel/zygisk.h"
#include "treat_wheel_adapter.h"

/* INFO: State path inside ReZygisk directory */
#define TW_STATE_PATH "/data/adb/rezygisk/tw_state"

static struct tw_module_state g_tw_state = { 0 };
static bool g_tw_initialized = false;

static void tw_load_state(void) {
  FILE *fp = fopen(TW_STATE_PATH, "r");
  if (!fp) {
    /* INFO: If state file doesn't exist, default to all-disabled (safe) */
    memset(&g_tw_state, 0, sizeof(g_tw_state));
    return;
  }

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

  if (!g_tw_initialized) {
    tw_adapter_init();
  }

  if (g_tw_state.is_ignoring) return;

  /* INFO: Reload state on every specialize to pick up WebUI changes */
  tw_load_state();
  if (g_tw_state.is_ignoring) return;

  bool on_denylist = (flags & PROCESS_ON_DENYLIST) == PROCESS_ON_DENYLIST;
  bool should_hide = false;

  if (!g_tw_state.disable_denylist_logic_inversion) {
    /* INFO: Inverted logic: denylist processes get Mounted, others get Clean */
    tw_do_denylist_logic_inversion(NULL, env, flags);
    /* INFO: After inversion, if process was on denylist, it now has Mounted ns,
     *       so we should still hide traces for it. */
    should_hide = on_denylist;
  } else {
    should_hide = on_denylist;
  }

  if (should_hide) {
    LOGI("Treat Wheel: process is on denylist (or inverted), running hiding.");

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
  bool should_hide = false;

  if (g_tw_state.disable_denylist_logic_inversion) {
    should_hide = on_denylist;
  } else {
    should_hide = !on_denylist;
  }

  if (should_hide && !g_tw_state.disable_module_loading_traces_hiding) {
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
