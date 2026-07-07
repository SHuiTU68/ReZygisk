#ifndef TREAT_WHEEL_ADAPTER_H
#define TREAT_WHEEL_ADAPTER_H

#include <stdbool.h>
#include <stdint.h>
#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

struct tw_module_state;

/* INFO: Initialize Treat Wheel (call once per zygote process) */
void tw_adapter_init(void);

/* INFO: Run hiding before app specialization.
 * env: JNI environment
 * process_name: target process name
 * flags: ReZygisk process flags (denylist, manager, etc.)
 */
void tw_adapter_pre_specialize(JNIEnv *env, const char *process_name, uint32_t flags);

/* INFO: Run cleanup/hiding before ReZygisk unloads itself.
 * env: JNI environment
 * flags: ReZygisk process flags
 */
void tw_adapter_atexit_cleanup(JNIEnv *env, uint32_t flags);

/* INFO: Check if a specific feature is enabled */
bool tw_adapter_is_enabled(const char *feature);

#ifdef __cplusplus
}
#endif

#endif /* TREAT_WHEEL_ADAPTER_H */
