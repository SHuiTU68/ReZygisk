#ifndef MAGISK_H
#define MAGISK_H

#include "common.h"

/* INFO: The variant values are also used as indexes of the manager paths
           array in magisk.c, so their order must not be changed. */
enum magisk_variants {
  MOfficial,
  MAlpha,
};

void magisk_get_existence(struct root_impl_state *state);

bool magisk_uid_granted_root(uid_t uid);

bool magisk_uid_should_umount(const char *const process);

bool magisk_uid_is_manager(uid_t uid);

#endif
