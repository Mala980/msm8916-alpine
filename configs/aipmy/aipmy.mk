# Build the ported aipmy/msm8916-openwrt userspace tools.
# Compile lines mirror the upstream OpenWrt package Makefiles.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
DESTDIR ?=

BINS = qcom-time-daemon ats-probe diag_efs diag_logtool reboot-mode-raw bt-spp diag_nv button-watch

all: $(BINS)

qcom-time-daemon: src/qcom-time-daemon.c src/qmi_time.c src/qmi_time.h
	$(CC) $(CFLAGS) -o $@ src/qcom-time-daemon.c src/qmi_time.c -lqrtr -lrt -lpthread

ats-probe: src/ats-probe.c src/qmi_time.c src/qmi_time.h
	$(CC) $(CFLAGS) -o $@ src/ats-probe.c src/qmi_time.c -lqrtr -lrt

diag_efs: src/diag_efs.c
	$(CC) $(CFLAGS) -o $@ src/diag_efs.c

diag_logtool: src/diag_logtool.c
	$(CC) $(CFLAGS) -o $@ src/diag_logtool.c

reboot-mode-raw: src/reboot-mode-raw.c
	$(CC) $(CFLAGS) -o $@ src/reboot-mode-raw.c

bt-spp: src/bt-spp.c
	$(CC) $(CFLAGS) -o $@ src/bt-spp.c

diag_nv: src/diag_nv.c
	$(CC) $(CFLAGS) -o $@ src/diag_nv.c

# button-watch's canonical source is configs/failsafe/button-watch.c;
# build-rootfs.sh stages it into src/ before invoking this Makefile.
button-watch: src/button-watch.c
	$(CC) $(CFLAGS) -o $@ src/button-watch.c

install: all
	for f in qcom-time-daemon ats-probe bt-spp; do install -Dm0755 $$f $(DESTDIR)/usr/sbin/$$f; done
	for f in diag_efs diag_logtool; do install -Dm0755 $$f $(DESTDIR)/usr/bin/$$f; done
	install -Dm0755 diag_nv $(DESTDIR)/usr/sbin/diag_nv
	install -Dm0755 button-watch $(DESTDIR)/usr/sbin/button-watch
	install -Dm0755 reboot-mode-raw $(DESTDIR)/sbin/reboot-mode-raw
	for f in diag-bind diag-bind-watch bt-ssp-guard bt-spp-server; do install -Dm0755 scripts/$$f $(DESTDIR)/usr/sbin/$$f; done
	install -Dm0755 scripts/reboot-mode $(DESTDIR)/sbin/reboot-mode
	ln -sf reboot-mode $(DESTDIR)/sbin/reboot-edl
	ln -sf reboot-mode $(DESTDIR)/sbin/reboot-dload
	mkdir -p $(DESTDIR)/etc/qcom-time
	# Round 2: modem-care daemons (usr/sbin), CLI tools (usr/local/sbin),
	# config templates and the carrier table.
	for f in modem-led-monitor wifi-led-monitor sim-hotplug modem-bearer-watchdog himi-ok-guard; do install -Dm0755 scripts/$$f $(DESTDIR)/usr/sbin/$$f; done
	mkdir -p $(DESTDIR)/usr/local/sbin
	for f in carrier-autocfg change-imei modem-care modem-bandlock lan-speed; do install -Dm0755 scripts/$$f $(DESTDIR)/usr/local/sbin/$$f; done
	install -Dm0644 etc/modem-care.conf $(DESTDIR)/etc/modem-care.conf
	install -Dm0644 etc/carrier-autocfg.conf $(DESTDIR)/etc/carrier-autocfg.conf
	install -Dm0644 etc/custom-apns.tsv $(DESTDIR)/etc/carrier-autocfg/custom-apns.tsv
	install -Dm0644 share/apns.tsv $(DESTDIR)/usr/share/carrier-autocfg/apns.tsv
	mkdir -p $(DESTDIR)/usr/share/carrier-autocfg/mcfg

clean:
	rm -f $(BINS)

.PHONY: all install clean
