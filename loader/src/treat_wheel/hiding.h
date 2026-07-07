#ifndef TW_HIDING_H
#define TW_HIDING_H

#include "../treat_wheel/zygisk.h"

struct tw_maps *tw_get_global_maps(void);

int tw_do_preinitialize(void);

void tw_do_deinitialize(void);

int tw_do_gsi_hiding(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_zygote_mountinfo_leak_hiding(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_maps_hiding(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_revanced_mounts_umount(struct api_table *api_table, JNIEnv *tw_env, const char *process_name);

int tw_do_custom_font_loading(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_denylist_logic_inversion(struct api_table *api_table, JNIEnv *tw_env, enum process_flags flags);

int tw_do_atexit_hiding(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_frida_hiding(struct api_table *api_table, JNIEnv *tw_env);

int tw_do_env_sanitization(struct api_table *api_table, JNIEnv *tw_env);

#endif /* TW_HIDING_H */
