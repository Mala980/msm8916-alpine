// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE
/*
 * button-watch.c - failsafe button monitor for the headless MSM8916
 *                  USB dongles (our adaptation, NOT OpenWrt preinit).
 *
 * The boards have exactly one user input: the Restart button
 * (DT node `button_restart`, gpio 23, a gpio-keys device).  This
 * daemon opens that input device and implements two gestures:
 *
 *   * SHORT PRESS within the first FAILSAFE_WINDOW seconds after
 *     this service starts  ->  rescue mode:
 *       - touch /run/failsafe-mode
 *       - make sure the USB gadget is up (runs `usb-gadget start`)
 *       - print a banner on the console and on /dev/ttyGS0
 *       - spawn a root login shell on /dev/ttyGS0 (the gadget ACM
 *         function, host side /dev/ttyACM0), respawned on exit
 *
 *   * HOLD for >= FACTORY_HOLD seconds (any time)  ->  factory reset:
 *       - delete everything listed in /etc/failsafe-reset.list
 *         (paths, globs, and the tokens "nm-connections" and
 *         "ssh-host-keys")
 *       - sync and reboot
 *
 * A short press after the boot window does nothing (the stock
 * OpenWrt handler reboots on a short press; on a device reachable
 * only over the network that is a footgun, so we deliberately
 * do not).
 *
 * The input device is found by scanning /dev/input/event* for the
 * gpio-keys device by name (EVIOCGNAME); the event number is never
 * hardcoded.
 *
 * Build: cc -O2 -Wall -o button-watch button-watch.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <glob.h>
#include <ftw.h>
#include <syslog.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include <linux/input.h>

#define FAILSAFE_WINDOW 15        /* seconds after service start */
#define FACTORY_HOLD    5         /* seconds */
#define RESET_LIST      "/etc/failsafe-reset.list"
#define FAILSAFE_MARK   "/run/failsafe-mode"
#define ACM_TTY         "/dev/ttyGS0"

static time_t start_mono;
static int rescue_done;

static time_t now_mono(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

static void logmsg(const char *msg)
{
    syslog(LOG_WARNING, "%s", msg);
    fprintf(stderr, "button-watch: %s\n", msg);
}

/* ------------------------------------------------------------------ */
/* Rescue mode                                                         */
/* ------------------------------------------------------------------ */

static void write_banner(const char *path)
{
    int fd = open(path, O_WRONLY | O_NOCTTY);
    if (fd < 0) return;
    const char *b =
        "\r\n"
        "==================================================\r\n"
        "  FAILSAFE / RESCUE MODE\r\n"
        "  USB gadget is up; a root login shell is running\r\n"
        "  on this console.  Marker: /run/failsafe-mode\r\n"
        "==================================================\r\n";
    (void)!write(fd, b, strlen(b));
    close(fd);
}

/* Supervisor child: keep a login shell on the ACM tty. */
static void acm_shell_supervisor(void)
{
    for (;;) {
        pid_t pid = fork();
        if (pid == 0) {
            setsid();
            int fd = open(ACM_TTY, O_RDWR);
            if (fd < 0) _exit(1);
            ioctl(fd, TIOCSCTTY, 0);
            dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
            if (fd > 2) close(fd);
            execl("/bin/login", "login", (char *)NULL);
            execl("/bin/sh", "sh", "-l", (char *)NULL);
            _exit(1);
        }
        if (pid < 0) { sleep(2); continue; }
        int st; waitpid(pid, &st, 0);
        sleep(1);
    }
}

static void enter_rescue(void)
{
    if (rescue_done) return;
    rescue_done = 1;
    logmsg("short press inside boot window: entering rescue mode");

    int fd = open(FAILSAFE_MARK, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) close(fd);

    /* Make sure the USB gadget (NCM + ACM) is up. */
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/sbin/usb-gadget", "usb-gadget", "start", (char *)NULL);
        _exit(0);
    }
    if (pid > 0) { int st; waitpid(pid, &st, 0); }

    write_banner("/dev/console");
    write_banner(ACM_TTY);

    pid = fork();
    if (pid == 0) { acm_shell_supervisor(); _exit(0); }
}

/* ------------------------------------------------------------------ */
/* Factory reset                                                       */
/* ------------------------------------------------------------------ */

static int rm_cb(const char *path, const struct stat *sb, int type, struct FTW *ftw)
{
    (void)sb; (void)type; (void)ftw;
    return remove(path);
}

static void delete_path(const char *path)
{
    struct stat st;
    if (lstat(path, &st) < 0) return;
    if (S_ISDIR(st.st_mode))
        nftw(path, rm_cb, 16, FTW_DEPTH | FTW_PHYS);
    else
        unlink(path);
}

static void delete_glob(const char *pattern)
{
    glob_t g;
    if (glob(pattern, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) delete_path(g.gl_pathv[i]);
        globfree(&g);
    }
}

static void factory_reset(void)
{
    logmsg("button held >= 5s: FACTORY RESET");
    FILE *f = fopen(RESET_LIST, "r");
    if (!f) {
        logmsg("no /etc/failsafe-reset.list; applying built-in minimum");
        delete_glob("/etc/NetworkManager/system-connections/*");
        delete_glob("/etc/ssh/ssh_host_*");
    } else {
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            char *s = line;
            while (*s == ' ' || *s == '\t') s++;
            size_t n = strlen(s);
            while (n && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' ')) s[--n] = 0;
            if (!n || s[0] == '#') continue;
            if (!strcmp(s, "nm-connections")) {
                delete_glob("/etc/NetworkManager/system-connections/*");
            } else if (!strcmp(s, "ssh-host-keys")) {
                delete_glob("/etc/ssh/ssh_host_*");
            } else if (strchr(s, '*') || strchr(s, '?')) {
                delete_glob(s);
            } else {
                delete_path(s);
            }
        }
        fclose(f);
    }
    unlink(FAILSAFE_MARK);
    sync();
    logmsg("factory reset done; rebooting");
    execl("/sbin/reboot", "reboot", (char *)NULL);
    reboot(RB_AUTOBOOT);
    _exit(1);
}

/* ------------------------------------------------------------------ */

static int find_gpio_keys(void)
{
    char path[64], name[256];
    for (int i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        name[0] = 0;
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
            strstr(name, "gpio-keys")) {
            syslog(LOG_INFO, "button-watch: using %s (%s)", path, name);
            return fd;
        }
        close(fd);
    }
    return -1;
}

int main(void)
{
    openlog("button-watch", LOG_PID, LOG_DAEMON);
    start_mono = now_mono();

    int fd = -1;
    while (fd < 0) {                 /* input device may appear late */
        fd = find_gpio_keys();
        if (fd < 0) sleep(2);
    }

    time_t press_time = 0;
    int pressed = 0;

    for (;;) {
        struct input_event ev;
        ssize_t n = read(fd, &ev, sizeof(ev));
        if (n != (ssize_t)sizeof(ev)) {
            if (n < 0 && errno == EINTR) continue;
            close(fd); fd = -1;
            while (fd < 0) { fd = find_gpio_keys(); if (fd < 0) sleep(2); }
            pressed = 0;
            continue;
        }
        if (ev.type != EV_KEY) continue;

        if (ev.value == 1) {                     /* press */
            pressed = 1;
            press_time = now_mono();
            if (press_time - start_mono <= FAILSAFE_WINDOW)
                enter_rescue();
        } else if (ev.value == 0 && pressed) {   /* release */
            pressed = 0;
            if (press_time && now_mono() - press_time >= FACTORY_HOLD)
                factory_reset();
        }
        /* ev.value == 2 (autorepeat) is ignored */
    }
    return 0;
}
