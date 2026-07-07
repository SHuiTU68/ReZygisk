#include <string.h>
#include <errno.h>
#include <time.h>

#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>

#include "../constants.h"
#include "../utils.h"
#include "common.h"

#include "kernelsu.h"

const char *ksu_manager_paths[] = {
  "/data/user_de/0/me.weishu.kernelsu",
  "/data/user_de/0/com.rifsxd.ksunext",
};

/* INFO: It would be presumed it is a unsigned int,
           so we need to cast it to signed int to
           avoid any potential UB.
*/
#define KSU_INSTALL_MAGIC1 (int)0xDEADBEEF
#define KSU_INSTALL_MAGIC2 (int)0xCAFEBABE

#define CMD_GET_VERSION 2
#define CMD_UID_GRANTED_ROOT 12
#define CMD_UID_SHOULD_UMOUNT 13
#define CMD_GET_MANAGER_UID 16
#define CMD_HOOK_MODE 0xC0DEAD1A

struct ksu_uid_granted_root_cmd {
  uint32_t uid;
  uint8_t granted;
};

struct ksu_uid_should_umount_cmd {
  uint32_t uid;
  uint8_t should_umount;
};

struct ksu_get_manager_uid_cmd {
  uint32_t uid;
};

struct ksu_set_feature_cmd {
  uint32_t feature_id;
  uint64_t value;
};

struct ksu_get_hook_mode_cmd {
  char mode[16];
};

#define KSU_IOCTL_UID_GRANTED_ROOT _IOC(_IOC_READ|_IOC_WRITE, 'K', 8, 0)
#define KSU_IOCTL_UID_SHOULD_UMOUNT _IOC(_IOC_READ|_IOC_WRITE, 'K', 9, 0)
#define KSU_IOCTL_GET_MANAGER_UID _IOC(_IOC_READ, 'K', 10, 0)
#define KSU_IOCTL_SET_FEATURE _IOC(_IOC_WRITE, 'K', 14, 0)

/* INFO: KernelSU-Next specific */
#define KSU_IOCTL_GET_HOOK_MODE _IOC(_IOC_READ, 'K', 98, 0)

static enum kernelsu_variants variant = KOfficial;

static int ksu_fd = -1;

static bool supports_manager_uid_retrieval = false;
static bool ksu_uses_new_ksuctl = false;

/* INFO: Manager UID cache. The manager package rarely changes, so cache it
 * permanently after first query to avoid one ioctl/prctl per app fork. */
static bool manager_uid_cached = false;
static uid_t cached_manager_uid = (uid_t)-1;

/* INFO: Denylist (should_umount) TTL cache, mirroring Magisk's approach.
 * KSU denylist is managed by ksud and changes infrequently, so a short TTL
 * avoids one ioctl per app fork. */
#define KSU_DENYLIST_CACHE_TTL_SEC 30
#define KSU_DENYLIST_CACHE_SIZE 64
struct ksu_denylist_entry {
  uid_t uid;
  bool should_umount;
  time_t timestamp;
};
static struct ksu_denylist_entry denylist_cache[KSU_DENYLIST_CACHE_SIZE];
static size_t denylist_cache_count = 0;

void ksu_get_existence(struct root_impl_state *state) {
  char platform[PROP_VALUE_MAX];
  get_property("ro.board.platform", platform);

  /* INFO: On Waydroid, the SYS_reboot call will trigger a SIGSYS signal, resulting
             in the crash of ReZygiskd. To avoid that, read the platform property
             and not try to call KernelSU v3 interface, jumping to KernelSU v1
             interface which doesn't require the SYS_reboot call. */
  if (strcmp(platform, "waydroid") == 0)
    goto try_prctl;

  syscall(SYS_reboot, KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, (void *)&ksu_fd);
  if (ksu_fd == -1) {
    try_prctl:

    /* INFO: Perhaps it uses the old ksuctl interface */
    int reply_ok = 0;

    int version = 0;
    prctl(KSU_INSTALL_MAGIC1, CMD_GET_VERSION, &version, 0, &reply_ok);

    if (version == 0) state->state = Abnormal;
    else if (version >= MIN_KSU_VERSION) {
      /* INFO: Some custom kernels for custom ROMs have pre-installed KernelSU.
              Some users don't want to use KernelSU, but, for example, Magisk.
              This if allows this to happen, as it checks if "ksud" exists,
              which in case it doesn't, it won't be considered as supported. */
      if (access("/data/adb/ksu/bin/ksud", F_OK) == -1) {
        LOGW("KernelSU %d detected, but ksud not found.", version);

        state->state = Inexistent;

        return;
      }

      state->state = Supported;

      char mode[16] = { 0 };
      prctl(KSU_INSTALL_MAGIC1, CMD_HOOK_MODE, mode, NULL, &reply_ok);

      if (mode[0] != '\0') state->variant = KNext;
      else state->variant = KOfficial;

      variant = state->variant;

      /* INFO: CMD_GET_MANAGER_UID is a KernelSU Next feature, however we won't
                limit to KernelSU Next only in case other forks wish to implement
                it. */
      prctl(KSU_INSTALL_MAGIC1, CMD_GET_MANAGER_UID, NULL, NULL, &reply_ok);

      if (reply_ok == KSU_INSTALL_MAGIC1) {
        LOGI("KernelSU implementation supports CMD_GET_MANAGER_UID.\n");

        supports_manager_uid_retrieval = true;
      }
    }
    else if (version >= 1 && version <= MIN_KSU_VERSION - 1) state->state = TooOld;
    else state->state = Abnormal;

    return;
  }

  if (access("/data/adb/ksu/bin/ksud", F_OK) == -1) {
    LOGW("KernelSU (ioctl) detected, but ksud not found.");

    state->state = Inexistent;

    return;
  }

  ksu_uses_new_ksuctl = true;

  struct ksu_set_feature_cmd cmd = {
    .feature_id = 1, /* INFO: kernel_umount */
    .value = 0
  };

  /* INFO: Tell KernelSU to not umount, and let us handle it */
  if (ioctl(ksu_fd, KSU_IOCTL_SET_FEATURE, &cmd) == -1) {
    LOGW("Failed to ioctl KSU_IOCTL_SET_FEATURE: %s\n", strerror(errno));

    /* INFO: Not a fatal error, just log and continue */
  }

  struct ksu_get_hook_mode_cmd hook_mode_cmd = { 0 };
  ioctl(ksu_fd, KSU_IOCTL_GET_HOOK_MODE, &hook_mode_cmd);

  if (hook_mode_cmd.mode[0] != '\0') state->variant = KNext;
  else state->variant = KOfficial;

  state->state = Supported;
}

bool ksu_uid_granted_root(uid_t uid) {
  if (!ksu_uses_new_ksuctl) {
    bool granted = false;
    uint32_t result = 0;
    prctl(KSU_INSTALL_MAGIC1, CMD_UID_GRANTED_ROOT, uid, &granted, &result);

    if ((int)result != KSU_INSTALL_MAGIC1) return false;

    return granted;
  }

  struct ksu_uid_granted_root_cmd cmd = {
    .uid = uid,
    .granted = 0
  };

  if (ioctl(ksu_fd, KSU_IOCTL_UID_GRANTED_ROOT, &cmd) == -1) {
    LOGE("Failed to ioctl KSU_IOCTL_UID_GRANTED_ROOT: %s\n", strerror(errno));

    return false;
  }

  return cmd.granted;
}

bool ksu_uid_should_umount(uid_t uid) {
  /* INFO: Check TTL cache first to avoid ioctl/prctl on every app fork. */
  time_t now = time(NULL);
  for (size_t i = 0; i < denylist_cache_count; i++) {
    if (denylist_cache[i].uid == uid) {
      if (now - denylist_cache[i].timestamp < KSU_DENYLIST_CACHE_TTL_SEC) {
        return denylist_cache[i].should_umount;
      }
      /* INFO: Expired, shift remaining entries down and re-query. */
      for (size_t j = i; j < denylist_cache_count - 1; j++) {
        denylist_cache[j] = denylist_cache[j + 1];
      }
      denylist_cache_count--;
      break;
    }
  }

  bool should_umount = false;
  if (!ksu_uses_new_ksuctl) {
    uint32_t result = 0;
    prctl(KSU_INSTALL_MAGIC1, CMD_UID_SHOULD_UMOUNT, uid, &should_umount, &result);

    if ((int)result != KSU_INSTALL_MAGIC1) return false;
  } else {
    struct ksu_uid_should_umount_cmd cmd = {
      .uid = uid,
      .should_umount = 0
    };

    if (ioctl(ksu_fd, KSU_IOCTL_UID_SHOULD_UMOUNT, &cmd) == -1) {
      LOGE("Failed to ioctl KSU_IOCTL_UID_SHOULD_UMOUNT: %s\n", strerror(errno));

      return false;
    }

    should_umount = cmd.should_umount;
  }

  /* INFO: Store in cache (evict oldest if full). */
  if (denylist_cache_count >= KSU_DENYLIST_CACHE_SIZE) {
    /* INFO: Evict the oldest entry (index 0). */
    for (size_t i = 0; i < denylist_cache_count - 1; i++) {
      denylist_cache[i] = denylist_cache[i + 1];
    }
    denylist_cache_count--;
  }
  denylist_cache[denylist_cache_count].uid = uid;
  denylist_cache[denylist_cache_count].should_umount = should_umount;
  denylist_cache[denylist_cache_count].timestamp = now;
  denylist_cache_count++;

  return should_umount;
}

bool ksu_uid_is_manager(uid_t uid) {
  /* INFO: If the manager UID is set, we can use it to check if the UID
             is the manager UID, which is more reliable than checking
             the KSU manager data directory, as spoofed builds of
             KernelSU Next have different package names.
  */
  if (!ksu_uses_new_ksuctl) {
    if (supports_manager_uid_retrieval) {
      /* INFO: Cache manager uid permanently - manager package rarely changes. */
      if (!manager_uid_cached) {
        int reply_ok = 0;

        uid_t manager_uid = 0;
        prctl(KSU_INSTALL_MAGIC1, CMD_GET_MANAGER_UID, &manager_uid, NULL, &reply_ok);

        cached_manager_uid = manager_uid;
        manager_uid_cached = true;
      }

      return uid == cached_manager_uid;
    }

    const char *manager_path = ksu_manager_paths[variant];
    struct stat st;
    if (stat(manager_path, &st) == -1) {
      if (errno != ENOENT) {
        LOGE("Failed to stat KSU manager data directory: %s", strerror(errno));
      }

      return false;
    }

    return st.st_uid == uid;
  }

  /* INFO: Cache manager uid permanently - manager package rarely changes. */
  if (!manager_uid_cached) {
    struct ksu_get_manager_uid_cmd cmd;
    if (ioctl(ksu_fd, KSU_IOCTL_GET_MANAGER_UID, &cmd) == -1) {
      LOGE("Failed to ioctl KSU_IOCTL_GET_MANAGER_UID: %s\n", strerror(errno));

      return false;
    }

    cached_manager_uid = cmd.uid;
    manager_uid_cached = true;
  }

  /* INFO: For Private Space, UID will be 10xxxxx, being xxxxx the original UID. To check if
             the UID is the manager UID in Private Space, we "normalize" it with the modulo operator. */
  return uid % 100000 == cached_manager_uid;
}

void ksu_cleanup(void) {
  if (ksu_fd != -1) {
    close(ksu_fd);
    ksu_fd = -1;
  }
}
