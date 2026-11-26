// SPDX-License-Identifier: GPL-2.0-only
/*
 * diag_nv.c - read or write a modem NV item BY ID over the SMD DIAG
 *             channel bridged to /dev/rpmsg0.
 *
 * Clean-room implementation written for this builder, providing the
 * diag_nv interface that aipmy/msm8916-openwrt ships as a prebuilt
 * binary (/usr/libexec/diag_nv.bin) plus a shell wrapper.  Only the
 * documented wire behaviour is reproduced:
 *
 *   - Transport: /dev/rpmsg0 (run diag-bind first), RAW frames, no
 *     HDLC and no CRC on requests; each read() returns one DIAG
 *     message; responses may carry a trailing 2-byte CRC + 0x7E.
 *     The channel also carries a continuous spontaneous F3 (0x79)
 *     stream, so replies are matched by echo bytes, like diag_efs.
 *   - NV_READ_F  = 0x26: request  [0x26][item u16 LE]
 *                        response [0x26][item][data 128][status u16 LE]
 *   - NV_WRITE_F = 0x27: request  [0x27][item][data 128][status u16 = 0]
 *                        response same shape as read.
 *   - status 0x0000 = NV_DONE (success); 0x42 is reported by the
 *     modem when the item is locked by the service-programming state.
 *     A response starting with 0x13 is a DIAG error response.
 *
 * /dev/rpmsg0 is exclusive-open: all operations are serialised on
 * /var/lock/himi-ok-diag.lock (shared with himi-ok-guard).
 *
 * Usage:
 *   diag_nv read  <item>          print the item as a hex dump + status
 *   diag_nv write <item> <hex>    write up to 128 bytes, read back, verify
 *   diag_nv raw   <hex>           send arbitrary DIAG bytes, print reply
 *
 * <item> is decimal or 0x-prefixed.  <hex> has no separators
 * (e.g. 48694d495f4f4b = "HiMI_OK").
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/file.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>

#define DEV_PATH   "/dev/rpmsg0"
#define LOCK_PATH  "/var/lock/himi-ok-diag.lock"
#define NV_READ_F  0x26
#define NV_WRITE_F 0x27
#define NV_LEN     128
#define RSP_LEN    (1 + 2 + NV_LEN + 2)   /* cmd + item + data + status */
#define BUFSZ      8192

static int g_fd = -1;

static int open_dev(void)
{
    if (g_fd >= 0) return 0;
    g_fd = open(DEV_PATH, O_RDWR);
    if (g_fd < 0) {
        fprintf(stderr, "diag_nv: open(%s): %s (is diag-bind running?)\n",
                DEV_PATH, strerror(errno));
        return -1;
    }
    return 0;
}

static int read_msg(unsigned char *buf, int bufsz, int timeout_ms)
{
    fd_set rfds; struct timeval tv;
    FD_ZERO(&rfds); FD_SET(g_fd, &rfds);
    tv.tv_sec = timeout_ms / 1000; tv.tv_usec = (timeout_ms % 1000) * 1000;
    int r = select(g_fd + 1, &rfds, NULL, NULL, &tv);
    if (r <= 0) return 0;
    ssize_t n = read(g_fd, buf, bufsz);
    if (n < 0) { fprintf(stderr, "diag_nv: read: %s\n", strerror(errno)); return -1; }
    return (int)n;
}

/*
 * Send a request, return the matching response length (0 = timeout).
 * A response matches when its first three bytes echo the request's
 * command code and item id; everything else on the channel (the F3
 * stream, log messages) is skipped within the time budget.
 */
static int nv_txn(const unsigned char *req, int n, unsigned char *resp, int timeout_ms)
{
    if (open_dev() < 0) return -1;
    if (write(g_fd, req, n) != n) {
        fprintf(stderr, "diag_nv: write: %s\n", strerror(errno));
        return -1;
    }
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long long budget_ns = (long long)timeout_ms * 1000000LL;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long long used = (t1.tv_sec - t0.tv_sec) * 1000000000LL + (t1.tv_nsec - t0.tv_nsec);
        long long left_ns = budget_ns - used;
        if (left_ns <= 0) break;
        int left_ms = (int)(left_ns / 1000000LL);
        if (left_ms < 1) left_ms = 1;
        if (left_ms > 250) left_ms = 250;
        int r = read_msg(resp, BUFSZ, left_ms);
        if (r < 0) return -1;
        if (r == 0) continue;
        if (resp[0] == 0x13) return r;              /* DIAG error response */
        if (r >= 3 && resp[0] == req[0] && resp[1] == req[1] && resp[2] == req[2])
            return r;
    }
    return 0;
}

/* Strip the trailing CRC + 0x7E the channel appends to responses. */
static int effective_len(const unsigned char *resp, int r)
{
    if (r >= 4 && resp[r - 1] == 0x7e) return r - 3;
    return r;
}

static void dump(const unsigned char *p, int n)
{
    for (int off = 0; off < n; off += 16) {
        int chunk = n - off; if (chunk > 16) chunk = 16;
        char hex[16 * 3 + 1]; char asc[17]; int h = 0;
        for (int i = 0; i < chunk; i++) {
            h += sprintf(hex + h, "%s%02x", i ? " " : "", p[off + i]);
            asc[i] = (p[off + i] >= 0x20 && p[off + i] < 0x7f) ? (char)p[off + i] : '.';
        }
        asc[chunk] = 0;
        printf("%04x  %s |%s|\n", off, hex, asc);
    }
}

/* One NV read. On success returns 0 and fills data/status. */
static int nv_read(uint16_t item, unsigned char data[NV_LEN], uint16_t *status)
{
    unsigned char req[3], resp[BUFSZ];
    req[0] = NV_READ_F; req[1] = item & 0xff; req[2] = (item >> 8) & 0xff;
    int r = nv_txn(req, 3, resp, 3000);
    if (r < 0) return -1;
    if (r == 0) { fprintf(stderr, "diag_nv: no response (timeout)\n"); return -1; }
    if (resp[0] == 0x13) {
        fprintf(stderr, "diag_nv: DIAG error response 0x13 (bad command / invalid parameter)\n");
        return -1;
    }
    int len = effective_len(resp, r);
    if (len < RSP_LEN) {
        fprintf(stderr, "diag_nv: short response (%d bytes)\n", len);
        return -1;
    }
    memcpy(data, resp + 3, NV_LEN);
    *status = (uint16_t)(resp[3 + NV_LEN] | (resp[3 + NV_LEN + 1] << 8));
    return 0;
}

static int cmd_read(uint16_t item)
{
    unsigned char data[NV_LEN]; uint16_t status = 0xffff;
    if (nv_read(item, data, &status) < 0) return 1;
    dump(data, NV_LEN);
    printf("status=0x%04x\n", status);
    return status == 0 ? 0 : 1;
}

static int cmd_write(uint16_t item, const unsigned char *data, int datalen)
{
    unsigned char req[RSP_LEN], resp[BUFSZ];
    memset(req, 0, sizeof(req));
    req[0] = NV_WRITE_F; req[1] = item & 0xff; req[2] = (item >> 8) & 0xff;
    memcpy(req + 3, data, datalen);           /* rest stays zero-padded */
    int r = nv_txn(req, RSP_LEN, resp, 3000);
    if (r < 0) return 1;
    if (r == 0) { fprintf(stderr, "diag_nv: no response (timeout)\n"); return 1; }
    if (resp[0] == 0x13) {
        fprintf(stderr, "diag_nv: DIAG error response 0x13 (bad command / invalid parameter)\n");
        return 1;
    }
    int len = effective_len(resp, r);
    if (len >= RSP_LEN) {
        uint16_t st = (uint16_t)(resp[3 + NV_LEN] | (resp[3 + NV_LEN + 1] << 8));
        printf("status=0x%04x\n", st);
        if (st != 0) {
            fprintf(stderr, "diag_nv: write status 0x%04x%s\n", st,
                    st == 0x42 ? " (NV locked by service-programming state)" : "");
            return 1;
        }
    }
    /* Read back and compare, like the reference tool. */
    unsigned char back[NV_LEN]; uint16_t status = 0xffff;
    if (nv_read(item, back, &status) < 0) return 1;
    unsigned char want[NV_LEN]; memset(want, 0, sizeof(want)); memcpy(want, data, datalen);
    if (memcmp(back, want, NV_LEN) == 0) {
        printf("VERIFY: MATCH\n");
        return 0;
    }
    printf("VERIFY: MISMATCH\n");
    dump(back, NV_LEN);
    return 1;
}

static int cmd_raw(const unsigned char *req, int n)
{
    unsigned char resp[BUFSZ];
    if (open_dev() < 0) return 1;
    if (write(g_fd, req, n) != n) {
        fprintf(stderr, "diag_nv: write: %s\n", strerror(errno));
        return 1;
    }
    int r = read_msg(resp, BUFSZ, 3000);
    if (r <= 0) { fprintf(stderr, "diag_nv: no response (timeout)\n"); return 1; }
    dump(resp, effective_len(resp, r));
    return 0;
}

static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex(const char *s, unsigned char *out, int max)
{
    int n = 0;
    while (s[0] && s[1]) {
        int hi = hexval((unsigned char)s[0]), lo = hexval((unsigned char)s[1]);
        if (hi < 0 || lo < 0 || n >= max) return -1;
        out[n++] = (unsigned char)((hi << 4) | lo);
        s += 2;
    }
    return s[0] ? -1 : n;
}

static void usage(FILE *f)
{
    fprintf(f,
"Usage: diag_nv {read <item> | write <item> <hexbytes> | raw <hexbytes>}\n"
"       diag_nv -h|--help\n"
"\n"
"Read or write a modem NV item BY ID over the SMD DIAG channel (/dev/rpmsg0),\n"
"using DIAG commands 0x26 (NV_READ_F) and 0x27 (NV_WRITE_F).  This is the raw\n"
"NV path, not EFS: use it for items that are not exposed under /nv/item_files.\n"
"\n"
"  <item>       NV item number, decimal or 0x-prefixed\n"
"  <hexbytes>   hex string without separators (e.g. 48694d495f4f4b = \"HiMI_OK\")\n"
"\n"
"Notes:\n"
"  * /dev/rpmsg0 is exclusive-open; operations are serialised on\n"
"    /var/lock/himi-ok-diag.lock.\n"
"  * Run diag-bind first (the diag-bind service keeps the bridge up).\n"
"\n"
"Examples:\n"
"  diag_nv read 550          (NV_UE_IMEI_I)\n"
"  diag_nv read 2500         (NV_FACTORY_DATA_4_I, the HiMI_OK item)\n"
"  diag_nv write 2500 48694d495f4f4b\n");
}

int main(int argc, char **argv)
{
    if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
        usage(argc < 2 ? stderr : stdout);
        return argc < 2 ? 2 : 0;
    }

    /* Serialise on the shared DIAG lock (best effort). */
    int lockfd = open(LOCK_PATH, O_RDWR | O_CREAT, 0644);
    if (lockfd >= 0) flock(lockfd, LOCK_EX);

    int rc;
    if (!strcmp(argv[1], "read") && argc == 3) {
        rc = cmd_read((uint16_t)strtoul(argv[2], NULL, 0));
    } else if (!strcmp(argv[1], "write") && argc == 4) {
        unsigned char data[NV_LEN];
        int n = parse_hex(argv[3], data, NV_LEN);
        if (n <= 0) { fprintf(stderr, "diag_nv: invalid hexbytes '%s'\n", argv[3]); return 2; }
        rc = cmd_write((uint16_t)strtoul(argv[2], NULL, 0), data, n);
    } else if (!strcmp(argv[1], "raw") && argc == 3) {
        unsigned char req[BUFSZ];
        int n = parse_hex(argv[2], req, BUFSZ);
        if (n <= 0) { fprintf(stderr, "diag_nv: invalid hexbytes '%s'\n", argv[2]); return 2; }
        rc = cmd_raw(req, n);
    } else {
        usage(stderr);
        return 2;
    }
    if (lockfd >= 0) { flock(lockfd, LOCK_UN); close(lockfd); }
    return rc;
}
