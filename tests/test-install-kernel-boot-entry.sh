#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/install-kernel-boot-entry.sh
CASE_DIR=$(mktemp -d)
trap 'rm -rf "$CASE_DIR"' EXIT HUP INT TERM

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

setup_case()
{
	case_dir=$1
	mkdir -p "$case_dir/boot/extlinux"
	printf 'stock kernel\n' | gzip >"$case_dir/boot/vmlinuz"
	printf 'custom kernel\n' | gzip >"$case_dir/boot/vmlinuz.custom"
	printf 'initramfs\n' >"$case_dir/boot/initramfs"
	printf '# device overrides\n' >"$case_dir/deviceinfo"
	printf '%s\n' 'quiet splash plymouth.ignore-serial-consoles plymouth.prefer-fbcon loglevel=2 pmos_boot_uuid=fe42ed99-f998-4835-8148-258cb0adc11d pmos_root_uuid=278d2c30-f65d-4ad5-883d-581c9d104bd2 pmos_rootfsopts=defaults' >"$case_dir/cmdline"
}

run_installer()
{
	case_dir=$1
	sha256=$2
	BOOT_DIR="$case_dir/boot" \
		DEVICEINFO_FILE="$case_dir/deviceinfo" \
		CMDLINE_FILE="$case_dir/cmdline" \
		sh "$SCRIPT" "$sha256"
}

assert_validated_config()
{
	expected=$1
	actual=$2
	cat >"$expected" <<'EOF'
timeout 5
default custom
menu title boot prev kernel

label custom
	kernel /vmlinuz.custom
	fdtdir /
	initrd /initramfs
	append quiet splash plymouth.ignore-serial-consoles plymouth.prefer-fbcon loglevel=2 pmos_boot_uuid=fe42ed99-f998-4835-8148-258cb0adc11d pmos_root_uuid=278d2c30-f65d-4ad5-883d-581c9d104bd2 pmos_rootfsopts=defaults

label stock
	kernel /vmlinuz
	fdtdir /
	initrd /initramfs
	append quiet splash plymouth.ignore-serial-consoles plymouth.prefer-fbcon loglevel=2 pmos_boot_uuid=fe42ed99-f998-4835-8148-258cb0adc11d pmos_root_uuid=278d2c30-f65d-4ad5-883d-581c9d104bd2 pmos_rootfsopts=defaults
EOF
	cmp -s "$expected" "$actual" ||
		fail 'generated extlinux config differs from the hardware-validated config'
}

setup_case "$CASE_DIR/valid"
sha256=$(sha256sum "$CASE_DIR/valid/boot/vmlinuz.custom" | awk '{print $1}')
stock_sha256=$(sha256sum "$CASE_DIR/valid/boot/vmlinuz" | awk '{print $1}')
run_installer "$CASE_DIR/valid" "$sha256" >/dev/null

assert_contains()
{
	pattern=$1
	file=$2
	grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

assert_contains 'default custom' "$CASE_DIR/valid/boot/extlinux/extlinux.conf"
assert_contains 'kernel /vmlinuz.custom' "$CASE_DIR/valid/boot/extlinux/extlinux.conf"
assert_contains 'label stock' "$CASE_DIR/valid/boot/extlinux/extlinux.conf"
assert_contains 'kernel /vmlinuz' "$CASE_DIR/valid/boot/extlinux/extlinux.conf"
assert_contains 'deviceinfo_generate_extlinux_config="false"' "$CASE_DIR/valid/deviceinfo"
assert_validated_config \
	"$CASE_DIR/extlinux.expected" \
	"$CASE_DIR/valid/boot/extlinux/extlinux.conf"
[ "$(grep -Fc 'deviceinfo_generate_extlinux_config=' "$CASE_DIR/valid/deviceinfo")" -eq 1 ] ||
	fail 'deviceinfo override was not idempotent'
[ "$(sha256sum "$CASE_DIR/valid/boot/vmlinuz" | awk '{print $1}')" = "$stock_sha256" ] ||
	fail 'stock kernel changed'

run_installer "$CASE_DIR/valid" "$sha256" >/dev/null
[ "$(grep -Fc 'deviceinfo_generate_extlinux_config=' "$CASE_DIR/valid/deviceinfo")" -eq 1 ] ||
	fail 'second install duplicated the deviceinfo override'

setup_case "$CASE_DIR/mismatch"
if run_installer "$CASE_DIR/mismatch" '0000000000000000000000000000000000000000000000000000000000000000' >/dev/null 2>&1; then
	fail 'kernel SHA-256 mismatch was accepted'
fi
[ ! -e "$CASE_DIR/mismatch/boot/extlinux/extlinux.conf" ] ||
	fail 'boot config was written after a hash mismatch'

setup_case "$CASE_DIR/conflict"
printf 'deviceinfo_generate_extlinux_config="true"\n' >>"$CASE_DIR/conflict/deviceinfo"
sha256=$(sha256sum "$CASE_DIR/conflict/boot/vmlinuz.custom" | awk '{print $1}')
if run_installer "$CASE_DIR/conflict" "$sha256" >/dev/null 2>&1; then
	fail 'conflicting deviceinfo setting was accepted'
fi
[ ! -e "$CASE_DIR/conflict/boot/extlinux/extlinux.conf" ] ||
	fail 'boot config was written after a deviceinfo conflict'

printf 'PASS: kernel boot entry installer tests\n'
