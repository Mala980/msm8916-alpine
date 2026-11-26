# Build the ported aipmy/msm8916-openwrt userspace tools.
# Compile lines mirror the upstream OpenWrt package Makefiles.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
DESTDIR ?=

BINS = qcom-time-daemon ats-probe diag_efs diag_logtool reboot-mode-raw bt-spp

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

install: all
	for f in qcom-time-daemon ats-probe bt-spp; do install -Dm0755 $$f $(DESTDIR)/usr/sbin/$$f; done
	for f in diag_efs diag_logtool; do install -Dm0755 $$f $(DESTDIR)/usr/bin/$$f; done
	install -Dm0755 reboot-mode-raw $(DESTDIR)/sbin/reboot-mode-raw
	for f in diag-bind diag-bind-watch bt-ssp-guard bt-spp-server; do install -Dm0755 scripts/$$f $(DESTDIR)/usr/sbin/$$f; done
	install -Dm0755 scripts/reboot-mode $(DESTDIR)/sbin/reboot-mode
	ln -sf reboot-mode $(DESTDIR)/sbin/reboot-edl
	ln -sf reboot-mode $(DESTDIR)/sbin/reboot-dload
	mkdir -p $(DESTDIR)/etc/qcom-time

clean:
	rm -f $(BINS)

.PHONY: all install clean
