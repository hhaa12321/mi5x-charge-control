#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

usage()
{
	printf 'usage: %s <custom-kernel-sha256>\n' "$0" >&2
	exit 2
}

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

cleanup()
{
	if [ -n "${tmp_file:-}" ] && [ -e "$tmp_file" ]; then
		rm -f "$tmp_file"
	fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$#" -eq 1 ] || usage
expected_sha256=$1
boot_dir=${BOOT_DIR:-/boot}
deviceinfo_file=${DEVICEINFO_FILE:-/etc/deviceinfo}
cmdline_file=${CMDLINE_FILE:-/proc/cmdline}
extlinux_dir=$boot_dir/extlinux
extlinux_file=$extlinux_dir/extlinux.conf

printf '%s\n' "$expected_sha256" | grep -Eq '^[0-9a-f]{64}$' ||
	die "custom kernel SHA-256 must be 64 lowercase hexadecimal characters"
[ -f "$boot_dir/vmlinuz" ] || die "missing $boot_dir/vmlinuz"
[ -f "$boot_dir/vmlinuz.custom" ] || die "missing $boot_dir/vmlinuz.custom"
[ -f "$boot_dir/initramfs" ] || die "missing $boot_dir/initramfs"
[ -f "$deviceinfo_file" ] || die "missing $deviceinfo_file"
[ -f "$cmdline_file" ] || die "missing $cmdline_file"

gzip -t "$boot_dir/vmlinuz" || die "$boot_dir/vmlinuz is not a gzip kernel image"
gzip -t "$boot_dir/vmlinuz.custom" ||
	die "$boot_dir/vmlinuz.custom is not a gzip kernel image"

actual_sha256=$(sha256sum "$boot_dir/vmlinuz.custom" | awk '{print $1}')
[ "$actual_sha256" = "$expected_sha256" ] ||
	die "custom kernel SHA-256 mismatch: expected $expected_sha256, got $actual_sha256"

[ "$(wc -l < "$cmdline_file")" -eq 1 ] ||
	die "$cmdline_file must contain exactly one line"
kernel_cmdline=$(sed -n '1p' "$cmdline_file")
[ -n "$kernel_cmdline" ] || die "$cmdline_file is empty"

if grep -Eq '^[[:space:]]*deviceinfo_generate_extlinux_config=' "$deviceinfo_file"; then
	{ grep -Fxq 'deviceinfo_generate_extlinux_config="false"' "$deviceinfo_file" ||
		grep -Fxq "deviceinfo_generate_extlinux_config='false'" "$deviceinfo_file" ||
		grep -Fxq 'deviceinfo_generate_extlinux_config=false' "$deviceinfo_file"; } ||
		die "$deviceinfo_file already sets deviceinfo_generate_extlinux_config to a non-false value"
else
	tmp_file=$(mktemp "$deviceinfo_file.tmp.XXXXXX")
	cp -p "$deviceinfo_file" "$tmp_file"
	printf '\n# Managed by mi5x-charge-control: keep the patched kernel boot entry.\ndeviceinfo_generate_extlinux_config="false"\n' >>"$tmp_file"
	mv "$tmp_file" "$deviceinfo_file"
	tmp_file=
fi

mkdir -p "$extlinux_dir"
tmp_file=$(mktemp "$extlinux_dir/.extlinux.conf.tmp.XXXXXX")
cat >"$tmp_file" <<EOF
timeout 5
default custom
menu title boot prev kernel

label custom
	kernel /vmlinuz.custom
	fdtdir /
	initrd /initramfs
	append $kernel_cmdline

label stock
	kernel /vmlinuz
	fdtdir /
	initrd /initramfs
	append $kernel_cmdline
EOF
chmod 0644 "$tmp_file"
mv "$tmp_file" "$extlinux_file"
tmp_file=
sync

printf 'custom kernel: %s\n' "$actual_sha256"
printf 'stock kernel:  %s\n' "$(sha256sum "$boot_dir/vmlinuz" | awk '{print $1}')"
printf 'boot config:   %s\n' "$extlinux_file"
printf 'reboot required to activate the custom kernel\n'
