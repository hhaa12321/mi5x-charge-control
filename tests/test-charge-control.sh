#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/openrc/mi5x-charge-control
TMP=$(mktemp -d)
CASE=0

cleanup()
{
	rm -r "$TMP"
}
trap cleanup EXIT HUP INT TERM

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq()
{
	expected=$1
	actual=$2
	message=$3

	[ "$actual" = "$expected" ] ||
		fail "$message (expected '$expected', got '$actual')"
}

assert_contains()
{
	file=$1
	text=$2

	grep -F -- "$text" "$file" >/dev/null ||
		fail "$file does not contain '$text'"
}

new_case()
{
	CASE=$((CASE + 1))
	CASE_DIR=$TMP/case-$CASE
	BATTERY=$CASE_DIR/sys/qcom-battery
	CHARGER=$CASE_DIR/sys/qcom-smbchg-usb
	CONFIG=$CASE_DIR/mi5x-charge-control.conf

	mkdir -p "$BATTERY" "$CHARGER"
	printf '[auto] inhibit-charge\n' >"$CHARGER/charge_behaviour"
	printf '70\n' >"$BATTERY/capacity"
	cat >"$CONFIG" <<EOF
MCC_UPPER=75
MCC_LOWER=60
MCC_INTERVAL=5
MCC_BATTERY_PATH=$BATTERY
MCC_CHARGER_PATH=$CHARGER
MCC_USE_SYSLOG=0
EOF
}

run_check()
{
	"$SCRIPT" --config "$CONFIG" check >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
}

run_once()
{
	"$SCRIPT" --config "$CONFIG" once >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
}

test_check()
{
	new_case
	run_check
	assert_contains "$CASE_DIR/stdout" 'kernel ABI ready, battery 70%, behaviour auto'
}

test_upper_threshold_stops_charging()
{
	new_case
	printf '80\n' >"$BATTERY/capacity"
	run_once
	assert_eq inhibit-charge "$(cat "$CHARGER/charge_behaviour")" \
		'capacity above upper threshold stops charging'
	assert_contains "$CASE_DIR/stderr" '80%: charge behaviour auto -> inhibit-charge'
}

test_lower_threshold_resumes_charging()
{
	new_case
	printf 'auto [inhibit-charge]\n' >"$CHARGER/charge_behaviour"
	printf '55\n' >"$BATTERY/capacity"
	run_once
	assert_eq auto "$(cat "$CHARGER/charge_behaviour")" \
		'capacity below lower threshold resumes charging'
}

test_midrange_preserves_state()
{
	new_case
	printf '70\n' >"$BATTERY/capacity"
	run_once
	assert_eq '[auto] inhibit-charge' "$(cat "$CHARGER/charge_behaviour")" \
		'midrange auto state is preserved'

	printf 'auto [inhibit-charge]\n' >"$CHARGER/charge_behaviour"
	run_once
	assert_eq 'auto [inhibit-charge]' "$(cat "$CHARGER/charge_behaviour")" \
		'midrange inhibit state is preserved'
}

test_idempotent_transition()
{
	new_case
	printf '90\n' >"$BATTERY/capacity"
	printf 'auto [inhibit-charge]\n' >"$CHARGER/charge_behaviour"
	run_once
	assert_eq 'auto [inhibit-charge]' "$(cat "$CHARGER/charge_behaviour")" \
		'already-inhibited state is not rewritten'
}

test_invalid_thresholds_fail()
{
	new_case
	sed -i 's/MCC_LOWER=60/MCC_LOWER=80/' "$CONFIG"
	if run_check; then
		fail 'invalid thresholds should fail'
	fi
	assert_contains "$CASE_DIR/stderr" 'MCC_UPPER must be greater than MCC_LOWER'
}

test_missing_abi_fails()
{
	new_case
	rm "$CHARGER/charge_behaviour"
	if run_check; then
		fail 'missing charge_behaviour should fail'
	fi
	assert_contains "$CASE_DIR/stderr" 'missing charge_behaviour ABI'
}

test_incomplete_abi_fails()
{
	new_case
	printf '[auto]\n' >"$CHARGER/charge_behaviour"
	if run_check; then
		fail 'missing inhibit-charge support should fail'
	fi
	assert_contains "$CASE_DIR/stderr" 'kernel must support auto and inhibit-charge'
}

test_daemon_stops_promptly()
{
	new_case
	"$SCRIPT" --config "$CONFIG" daemon >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" &
	pid=$!

	sleep 0.2
	kill -0 "$pid" 2>/dev/null || fail 'daemon exited unexpectedly'
	kill -TERM "$pid"

	status=0
	wait "$pid" || status=$?
	assert_eq 0 "$status" 'daemon exits cleanly on SIGTERM'
}

test_check
test_upper_threshold_stops_charging
test_lower_threshold_resumes_charging
test_midrange_preserves_state
test_idempotent_transition
test_invalid_thresholds_fail
test_missing_abi_fails
test_incomplete_abi_fails
test_daemon_stops_promptly

printf 'PASS: %s charge-control tests\n' "$CASE"
