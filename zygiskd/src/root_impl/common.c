#include "common.h"

#include "../utils.h"
#include "magisk.h"

static struct root_impl impl;

void root_impls_setup(void) {
  struct root_impl_state state_magisk = { 0 };
  magisk_get_existence(&state_magisk);

  if (state_magisk.state == Supported) {
    impl.impl = Magisk;
    impl.variant = state_magisk.variant;

    LOGI("Magisk%s root implementation found.\n", impl.variant == MAlpha ? " Alpha" : "");
  } else {
    impl.impl = None;

    LOGI("No root implementation found.\n");
  }
}

void get_impl(struct root_impl *uimpl) {
  *uimpl = impl;
}

bool uid_granted_root(uid_t uid) {
  if (impl.impl != Magisk) return false;

  return magisk_uid_granted_root(uid);
}

bool uid_should_umount(const char *const process) {
  if (impl.impl != Magisk) return false;

  return magisk_uid_should_umount(process);
}

bool uid_is_manager(uid_t uid) {
  if (impl.impl != Magisk) return false;

  return magisk_uid_is_manager(uid);
}
