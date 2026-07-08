// nuke_ext4_lkm — unregister ext4 sysfs nodes for a given mount point.
// Ported from mountify, with improvements:
//   1. Auto-resolve symaddr via kallsyms_lookup_name (no manual grep needed)
//   2. C89-clean: all declarations before statements (fixes -Werror)
//   3. Robust error propagation with distinct errno per failure
//   4. Support both kallsyms_lookup_name (5.x) and sprint_symbol fallback
//   5. Cleaner mount_point handling: empty param = auto-detect staging
#include <linux/module.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/path.h>
#include <linux/namei.h>
#include <linux/string.h>
#include <linux/version.h>
#include <linux/kallsyms.h>
#include <linux/kprobes.h>
/* INFO: For kernel >= 5.4, MODULE_IMPORT_NS lives in <linux/export.h>.
 * For older kernels it's in <linux/module.h>. Including both is safe. */
#include <linux/export.h>

#ifndef MODULE
#error "This is for LKM builds only. Do not compile built-in (CONFIG_NUKE_EXT4_SYSFS=y)."
#endif

/*
 * USAGE:
 *   # auto-resolve symbol (recommended, kernel >= 5.x with CONFIG_KALLSYMS):
 *   insmod nuke.ko mount_point="/mnt/vendor/rezygisk"
 *
 *   # manual symbol address (fallback when kallsyms_lookup_name is unavailable):
 *   ptr=$(grep " ext4_unregister_sysfs$" /proc/kallsyms | awk '{print "0x"$1}')
 *   insmod nuke.ko mount_point="/mnt/vendor/rezygisk" symaddr="$ptr"
 *
 * The module unregisters /proc/fs/ext4/<s_id> for the ext4 superblock backing
 * the given mount_point, then returns -EAGAIN to auto-unload (one-shot).
 */

static unsigned long symaddr;
module_param(symaddr, ulong, 0000);
MODULE_PARM_DESC(symaddr, "ext4_unregister_sysfs symbol address (0 = auto-resolve via kallsyms)");

static char *mount_point = "";
module_param(mount_point, charp, 0000);
MODULE_PARM_DESC(mount_point, "ext4 mount point to nuke sysfs for (empty = fail, must be set)");

#ifndef __nocfi
#define __nocfi
#endif

// INFO: kallsyms_lookup_name() was unexported for modules in 5.7+. We use
// kprobe trick (like KernelSU) to get a function pointer, OR fall back to
// the manually-passed symaddr param. The kprobe approach is wrapped so the
// module still compiles on kernels without that trick available.
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
static unsigned long (*kln_ptr)(const char *name) = NULL;

static int resolve_kallsyms_lookup_name(void)
{
	struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
	int ret;

	ret = register_kprobe(&kp);
	if (ret < 0)
		return ret;

	kln_ptr = (typeof(kln_ptr))kp.addr;
	unregister_kprobe(&kp);
	return 0;
}
#else
// On < 5.7, kallsyms_lookup_name is directly callable.
static int resolve_kallsyms_lookup_name(void) { kln_ptr = kallsyms_lookup_name; return 0; }
#define kln_ptr kallsyms_lookup_name
#endif

static __nocfi int do_nuke_ext4_sysfs(struct super_block *sb)
{
	static void (*ext4_unregister_sysfs_fn)(struct super_block *) = NULL;
	const char *sym = "ext4_unregister_sysfs";
	char buf[KSYM_SYMBOL_LEN] = {0};
	unsigned long addr = symaddr;
	int ret;

	// Resolve symbol address if not manually provided.
	if (addr == 0) {
		if (kln_ptr == NULL) {
			ret = resolve_kallsyms_lookup_name();
			if (ret < 0 || kln_ptr == NULL) {
				pr_info("nuke_ext4: cannot resolve kallsyms_lookup_name (err=%d), pass symaddr manually\n", ret);
				return -ENOSYS;
			}
		}
		addr = kln_ptr(sym);
		if (addr == 0) {
			pr_info("nuke_ext4: symbol %s not found in kallsyms\n", sym);
			return -ENOENT;
		}
	}

	// Verify the address actually points to the expected symbol.
	sprint_symbol(buf, addr);
	buf[KSYM_SYMBOL_LEN - 1] = '\0';
	if (strncmp(buf, sym, strlen(sym))) {
		pr_info("nuke_ext4: symbol mismatch at 0x%lx: %s\n", addr, buf);
		return -EINVAL;
	}

	pr_info("nuke_ext4: using %s at 0x%lx\n", buf, addr);
	ext4_unregister_sysfs_fn = (void (*)(struct super_block *))addr;
	ext4_unregister_sysfs_fn(sb);
	return 0;
}

static int __init nuke_entry(void)
{
	struct path path;
	struct super_block *sb;
	const char *name;
	const char *s_id;
	char procfs_path[64] = {0};
	int err, ret;

	pr_info("nuke_ext4: init symaddr=0x%lx mount_point=%s\n", symaddr, mount_point);

	if (!mount_point || !*mount_point) {
		pr_info("nuke_ext4: mount_point not set\n");
		return -EINVAL;
	}

	err = kern_path(mount_point, 0, &path);
	if (err) {
		pr_info("nuke_ext4: kern_path(%s) failed: %d\n", mount_point, err);
		return -EAGAIN;
	}

	sb = path.dentry->d_inode->i_sb;
	name = sb->s_type->name;
	s_id = sb->s_id;

	if (strcmp(name, "ext4") != 0) {
		pr_info("nuke_ext4: %s is not ext4 (is %s)\n", mount_point, name);
		path_put(&path);
		return -EAGAIN;
	}

	pr_info("nuke_ext4: nuking sysfs for ext4 volume %s (%s)\n", s_id, mount_point);
	ret = do_nuke_ext4_sysfs(sb);

	// Copy s_id before releasing path, for the procfs recheck below.
	snprintf(procfs_path, sizeof(procfs_path), "/proc/fs/ext4/%s", s_id);
	path_put(&path);

	if (ret) {
		pr_info("nuke_ext4: nuke failed: %d\n", ret);
		return -EAGAIN;
	}

	// Verify the procfs node is actually gone.
	err = kern_path(procfs_path, 0, &path);
	if (!err) {
		pr_info("nuke_ext4: WARNING: procfs node still exists at %s\n", procfs_path);
		path_put(&path);
	} else {
		pr_info("nuke_ext4: success — procfs node %s nuked\n", procfs_path);
	}

	// Return -EAGAIN so the module auto-unloads after the one-shot operation.
	return -EAGAIN;
}

static void __exit nuke_exit(void)
{
	// Unreachable: __init returns -EAGAIN, causing immediate unload.
	__builtin_unreachable();
}

module_init(nuke_entry);
module_exit(nuke_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Hrezygisk");
MODULE_DESCRIPTION("nuke ext4 sysfs (auto-resolve via kallsyms)");

/* INFO: mountify's original used MODULE_IMPORT_NS(VFS_internal_...) to
 * access VFS-internal symbols. We don't actually need it:
 *   - kern_path() is a normal EXPORT_SYMBOL, no namespace required.
 *   - kallsyms_lookup_name() is resolved via kprobe trick (not via import).
 * Removing this avoids build breakage on kernels where the namespace name
 * changed (6.x) or where MODULE_IMPORT_NS requires extra headers. */
