SCRIPT := openrc/mi5x-charge-control
INITD := openrc/mi5x-charge-control.initd
CONFD := openrc/mi5x-charge-control.confd
KERNEL_TEST := scripts/test-kernel-patch.sh
BOOT_ENTRY_INSTALLER := scripts/install-kernel-boot-entry.sh
BOOT_ENTRY_TEST := tests/test-install-kernel-boot-entry.sh

DESTDIR ?=
SBINDIR ?= /usr/sbin
INITDIR ?= /etc/init.d
CONFDIR ?= /etc/conf.d

.PHONY: all test lint kernel-test install uninstall

all: lint test

test:
	sh tests/test-charge-control.sh
	sh $(BOOT_ENTRY_TEST)

lint:
	sh -n $(SCRIPT)
	sh -n $(INITD)
	sh -n tests/test-charge-control.sh
	sh -n $(BOOT_ENTRY_INSTALLER)
	sh -n $(BOOT_ENTRY_TEST)
	sh -n $(KERNEL_TEST)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SCRIPT) $(BOOT_ENTRY_INSTALLER) tests/test-charge-control.sh \
			$(BOOT_ENTRY_TEST) $(KERNEL_TEST); \
	fi

kernel-test:
	$(KERNEL_TEST) v7.0.9-r0

install:
	install -d $(DESTDIR)$(SBINDIR) $(DESTDIR)$(INITDIR) $(DESTDIR)$(CONFDIR)
	install -m 0755 $(SCRIPT) $(DESTDIR)$(SBINDIR)/mi5x-charge-control
	install -m 0755 $(INITD) $(DESTDIR)$(INITDIR)/mi5x-charge-control
	@if [ ! -e $(DESTDIR)$(CONFDIR)/mi5x-charge-control ]; then \
		install -m 0644 $(CONFD) $(DESTDIR)$(CONFDIR)/mi5x-charge-control; \
	else \
		printf '%s\n' 'Keeping existing $(DESTDIR)$(CONFDIR)/mi5x-charge-control'; \
	fi

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/mi5x-charge-control
	rm -f $(DESTDIR)$(INITDIR)/mi5x-charge-control
	@printf '%s\n' 'Configuration kept at $(DESTDIR)$(CONFDIR)/mi5x-charge-control'
