#ifndef COMMON_H
#define COMMON_H

#include <stdint.h>

#include <sys/types.h>

#include "../constants.h"

enum root_impls {
  None,
  Magisk
};

struct root_impl_state {
  enum RootImplState state;
  uint8_t variant;
};

struct root_impl {
  enum root_impls impl;
  uint8_t variant;
};

#define LONGEST_ROOT_IMPL_NAME sizeof("Magisk Alpha")

void root_impls_setup(void);

void get_impl(struct root_impl *uimpl);

bool uid_granted_root(uid_t uid);

bool uid_should_umount(const char *const process);

bool uid_is_manager(uid_t uid);

#endif /* COMMON_H */
