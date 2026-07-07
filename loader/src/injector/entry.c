#include "daemon.h"
#include "logging.h"
#include "misc.h"

#include "hook.h"
#include "ptrace_clear.h"

#include "treat_wheel_adapter.h"

__attribute__((visibility("default")))
void entry(void *addr, size_t size, int tango_flag) {
  LOGD("ReZygisk%s library injected, version %s", tango_flag ? " [TANGO]" : "", ZKSU_VERSION);

  start_addr = addr;
  block_size = size;

  /* INFO: Connect to the daemon BEFORE installing hooks. If the daemon is not
   * running, we avoid leaving the zygote in a half-hooked state where PLT
   * hooks are installed but no daemon coordinates them — such a state would
   * cause hook callbacks to reference uninitialized data or attempt to
   * connect to a non-existent daemon, risking zygote crashes and creating
   * a detectable Zygisk fingerprint. */
  if (!rezygiskd_zygote_injected()) {
    LOGE("ReZygiskd is not running, skipping hook installation");

    return;
  }

  LOGD("start plt hooking");
  hook_functions();

  /* INFO: Initialize Treat Wheel hiding system */
  tw_adapter_init();

  struct kernel_version version = parse_kversion();
  if (version.major > 3 || (version.major == 3 && version.minor >= 8)) {
    LOGD("Supported kernel version %d.%d.%d, sending seccomp event", version.major, version.minor, version.patch);

    perform_ptrace_message_clear();
  }

  LOGD("Zygisk library execution done, addr: %p, size: %zu", addr, size);
}
