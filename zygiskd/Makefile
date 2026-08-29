ROOT_DIR := ..
include ../common.mk

BUILD_DIR ?= $(ROOT_DIR)/build

OBJ_ROOT = $(BUILD_DIR)/obj/$(BUILD_TYPE)/zygiskd
OBJ_DIR = $(OBJ_ROOT)/$(ARCH)

ZKSU_VERSION ?= $(VER_NAME)

ifeq ($(BUILD_TYPE),release)
	CARGO_PROFILE_FLAG = --release
	CARGO_PROFILE_DIR = release
else
	CARGO_PROFILE_FLAG =
	CARGO_PROFILE_DIR = debug
endif

RUST_DIR = $(ROOT_DIR)/zygiskd-rs
TOOLCHAIN_BIN = $(TOOLCHAIN)/bin

# Map module ABIs (ARCHS in common.mk) to Rust target triples and NDK clang wrappers
RUST_TARGET_arm64-v8a = aarch64-linux-android
RUST_TARGET_armeabi-v7a = armv7-linux-androideabi
RUST_TARGET_x86 = i686-linux-android
RUST_TARGET_x86_64 = x86_64-linux-android

NDK_LINKER_arm64-v8a = $(TOOLCHAIN_BIN)/aarch64-linux-android$(API_LEVEL)-clang
NDK_LINKER_armeabi-v7a = $(TOOLCHAIN_BIN)/armv7a-linux-androideabi$(API_LEVEL)-clang
NDK_LINKER_x86 = $(TOOLCHAIN_BIN)/i686-linux-android$(API_LEVEL)-clang
NDK_LINKER_x86_64 = $(TOOLCHAIN_BIN)/x86_64-linux-android$(API_LEVEL)-clang

# Runtime constants baked into the daemon (see zygiskd-rs/build.rs)
export MIN_APATCH_VERSION
export ZKSU_VERSION

.PHONY: all clean FORCE

all:
	@for arch in $(ARCHS); do                                                                                  \
		$(MAKE) BUILD_TYPE=$(BUILD_TYPE) BUILD_DIR=$(BUILD_DIR) ARCH=$$arch ZKSU_VERSION=$(ZKSU_VERSION) arch; \
	done
	@mkdir -p $(OBJ_ROOT)
	@touch $(OBJ_ROOT)/.done

arch: $(OBJ_DIR)/zygiskd

$(OBJ_DIR)/zygiskd: FORCE
	@mkdir -p $(dir $@)
	@cd $(RUST_DIR) && export CARGO_TARGET_$$(echo $(RUST_TARGET_$(ARCH)) | tr '[:lower:]-' '[:upper:]_')_LINKER=$(NDK_LINKER_$(ARCH)); \
		cargo build --target $(RUST_TARGET_$(ARCH)) $(CARGO_PROFILE_FLAG) && \
		cp target/$(RUST_TARGET_$(ARCH))/$(CARGO_PROFILE_DIR)/zygiskd $@

FORCE:

clean:
	rm -rf $(BUILD_DIR)/obj/$(BUILD_TYPE)/zygiskd
