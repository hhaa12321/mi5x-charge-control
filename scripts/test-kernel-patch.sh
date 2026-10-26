#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

KERNEL_REPO=${KERNEL_REPO:-https://github.com/msm8953-mainline/linux.git}
JOBS=${JOBS:-2}
TAG=${1:-v7.0.9-r0}
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PATCH=$ROOT/kernel/patches/0001-power-supply-qcom-smbchg-add-charge-behaviour.patch
WORKDIR=$(mktemp -d)
SOURCE=$WORKDIR/linux

find_llvm()
{
	if [ -n "${LLVM:-}" ]; then
		printf '%s\n' "$LLVM"
		return
	fi

	for candidate in 1 -22 -21 -20 -19 -18 -17; do
		case "$candidate" in
		1) suffix= ;;
		*) suffix=$candidate ;;
		esac

		complete=1
		for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-readelf llvm-strip; do
			command -v "$tool$suffix" >/dev/null 2>&1 || complete=0
		done
		if [ "$complete" -eq 1 ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
}

cleanup()
{
	rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

LLVM_VALUE=$(find_llvm)
[ -n "$LLVM_VALUE" ] ||
	{
		printf '%s\n' 'Clang/LLVM tools were not found; set LLVM=1 or LLVM=-NN' >&2
		exit 1
	}

printf 'Cloning msm8953-mainline/linux %s\n' "$TAG"
git clone --quiet --depth 1 --branch "$TAG" --filter=blob:none \
	"$KERNEL_REPO" "$SOURCE"

git -C "$SOURCE" apply --check "$PATCH"
git -C "$SOURCE" apply "$PATCH"

make -C "$SOURCE" ARCH=arm64 LLVM="$LLVM_VALUE" defconfig
"$SOURCE/scripts/config" --file "$SOURCE/.config" \
	--enable POWER_SUPPLY \
	--enable REGULATOR \
	--enable EXTCON \
	--enable MFD_SPMI_PMIC \
	--enable CHARGER_QCOM_SMBCHG
make -C "$SOURCE" ARCH=arm64 LLVM="$LLVM_VALUE" olddefconfig

grep -q '^CONFIG_CHARGER_QCOM_SMBCHG=y$' "$SOURCE/.config" ||
	{
		printf '%s\n' 'CONFIG_CHARGER_QCOM_SMBCHG did not become enabled' >&2
		exit 1
	}

make -C "$SOURCE" ARCH=arm64 LLVM="$LLVM_VALUE" -j"$JOBS" \
	drivers/power/supply/qcom-smbchg.o
test -s "$SOURCE/drivers/power/supply/qcom-smbchg.o"

printf 'PASS: %s qcom-smbchg.o compiled with charge_behaviour support\n' "$TAG"
