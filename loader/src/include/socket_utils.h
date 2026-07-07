#ifndef SOCKET_UTILS_H
#define SOCKET_UTILS_H

#include <stdint.h>

#include <sys/types.h>

/* INFO: Maximum allowed length for a string received via socket.
 * Prevents integer overflow (str_len + 1) on 32-bit and DoS via huge alloc. */
#define MAX_STRING_LEN (1024 * 1024)

/* INFO: Maximum allowed number of modules to prevent integer overflow on
 * malloc (count * sizeof(char *)) and DoS via huge count. */
#define MAX_MODULES_COUNT 4096

ssize_t write_loop(int fd, const void *buf, size_t count);

ssize_t read_loop_offset(int fd, void *buf, size_t len, off_t off);

ssize_t read_loop(int fd, void *buf, size_t len);

ssize_t write_fd(int fd, int sendfd);

int read_fd(int fd);

ssize_t write_string(int fd, const char *str);

char *read_string(int fd);

#define write_func_def(type)              \
  ssize_t write_## type(int fd, type val)

#define read_func_def(type)               \
  ssize_t read_## type(int fd, type *val)

write_func_def(uint8_t);
read_func_def(uint8_t);

write_func_def(uint32_t);
read_func_def(uint32_t);

write_func_def(size_t);
read_func_def(size_t);

#endif /* SOCKET_UTILS_H */
