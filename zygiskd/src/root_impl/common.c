#include <sys/types.h>

#include "common.h"

#include "../utils.h"
#include "apatch.h"

static struct root_impl impl;

void root_impls_setup(void) {
  struct root_impl_state state_apatch;
  apatch_get_existence(&state_apatch);

  if (state_apatch.state == Supported) {
    impl.impl = APatch;
  }

  switch (impl.impl) {
    case APatch: {
      LOGI("APatch root implementation found.\n");

      break;
    }
  }
}

void get_impl(struct root_impl *uimpl) {
  *uimpl = impl;
}

bool uid_granted_root(uid_t uid) {
  switch (impl.impl) {
    case APatch: {
      return apatch_uid_granted_root(uid);
    }
  }
}

bool uid_should_umount(uid_t uid, const char *const process) {
  switch (impl.impl) {
    case APatch: {
      return apatch_uid_should_umount(uid, process);
    }
  }
}

bool uid_is_manager(uid_t uid) {
  switch (impl.impl) {
    case APatch: {
      return apatch_uid_is_manager(uid);
    }
  }
}

void root_impl_cleanup(void) {
  /* INFO: APatch has no cleanup needed */
}
