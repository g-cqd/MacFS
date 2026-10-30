// Disk geometry for FileBlockSource. Not a kernel: the ioctl request macros are function-like,
// so Swift cannot import them, and this is the smallest place to expand them.
#include "fskernels.h"

#if defined(__APPLE__)
#include <sys/disk.h>
#include <sys/ioctl.h>

int32_t fsk_device_geometry(int32_t fd, uint32_t *blockSize, uint64_t *blockCount) {
    if (ioctl(fd, DKIOCGETBLOCKSIZE, blockSize) != 0) return -1;
    if (ioctl(fd, DKIOCGETBLOCKCOUNT, blockCount) != 0) return -1;
    return 0;
}
#else
#include <errno.h>

int32_t fsk_device_geometry(int32_t fd, uint32_t *blockSize, uint64_t *blockCount) {
    (void)fd;
    *blockSize = 0;
    *blockCount = 0;
    errno = ENOTSUP;
    return -1;
}
#endif
