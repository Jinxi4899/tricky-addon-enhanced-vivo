#!/bin/sh

# Resolve a working resetprop binary.
#
# The bundled resetprop-rs (Rust reimplementation) cannot always override the
# read-only `bootloader_prop` properties (e.g. ro.boot.vbmeta.device_state),
# which is why ro.boot.verifiedbootstate / ro.boot.flash.locked could be spoofed
# but ro.boot.vbmeta.device_state silently failed.
#
# The root manager's native resetprop (KernelSU / APatch / Magisk) hooks the
# property service and CAN override those read-only props, so we prefer it,
# then fall back to a system resetprop on PATH, then to the bundled resetprop-rs.
resolve_resetprop() {
    local cand
    for cand in \
        "/data/adb/ksu/bin/resetprop" \
        "/data/adb/ap/bin/resetprop" \
        "/data/adb/magisk/resetprop" \
        "$(command -v resetprop 2>/dev/null)" ; do
        [ -n "$cand" ] && [ -x "$cand" ] && { echo "$cand"; return; }
    done
    # Self-locate the bundled resetprop-rs by ABI (last resort).
    local mod="${MODPATH:-${MODDIR:-${0%/*}}}"
    local a
    for a in arm64-v8a armeabi-v7a x86_64 x86; do
        cand="$mod/bin/$a/resetprop-rs"
        [ -x "$cand" ] && { echo "$cand"; return; }
    done
    echo "resetprop"
}

RP=$(resolve_resetprop)
export RP

# Lightweight logger so spoof failures are visible after reinstall.
_prop_log() {
    local f="/data/adb/tricky_store/ta-enhanced/logs/prop.log"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$f" 2>/dev/null
}
_prop_log "Using resetprop: $RP"

check_reset_prop() {
    local NAME=$1
    local EXPECTED=$2
    local VALUE=$($RP $NAME 2>/dev/null)
    if [ -z "$VALUE" ] || [ "$VALUE" = "$EXPECTED" ]; then
        return 0
    fi
    if ! $RP -n "$NAME" "$EXPECTED" 2>/dev/null; then
        _prop_log "WARN: set failed: $NAME -> $EXPECTED (resetprop may be unable to override this read-only prop)"
        return 1
    fi
    # Verify the spoof actually took effect.
    VALUE=$($RP "$NAME" 2>/dev/null)
    if [ "$VALUE" != "$EXPECTED" ]; then
        _prop_log "WARN: spoof did not stick: $NAME still $VALUE (expected $EXPECTED)"
        return 1
    fi
    _prop_log "OK: $NAME -> $EXPECTED"
    return 0
}

contains_reset_prop() {
    local NAME=$1
    local CONTAINS=$2
    local NEWVAL=$3
    case "$($RP $NAME 2>/dev/null)" in
        *"$CONTAINS"*) $RP -n "$NAME" "$NEWVAL" 2>/dev/null ;;
    esac
}

empty_reset_prop() {
    local NAME=$1
    local NEWVAL=$2
    local VALUE=$(getprop "$NAME" 2>/dev/null)
    [ -z "$VALUE" ] && $RP -n "$NAME" "$NEWVAL" 2>/dev/null
}

# Force-set a critical bootloader prop using the native resetprop.
# Tries the standard `-n` form, then a plain set, then re-verifies. Used for the
# three bootloader-unlock signals the 春秋 detector reads.
force_boot_prop() {
    local NAME=$1 EXPECTED=$2
    check_reset_prop "$NAME" "$EXPECTED" && return 0
    # Retry without -n (some resetprop builds treat -n as "only if exists").
    $RP "$NAME" "$EXPECTED" 2>/dev/null
    check_reset_prop "$NAME" "$EXPECTED"
}

$RP -w sys.boot_completed 0

if [ -f "/data/adb/disable_prop_handler" ]; then
    exit 0
fi

if [ ! -f "/data/adb/disable_vbmeta_digest_spoof" ] && [ -f "/data/adb/boot_hash" ]; then
    hash_value=$(grep -v '^#' "/data/adb/boot_hash" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -z "$hash_value" ] && rm -f /data/adb/boot_hash || $RP -n ro.boot.vbmeta.digest "$hash_value"
fi

# Critical bootloader-unlock signals read by the 春秋 detector and similar.
# Use force_boot_prop so a read-only bootloader_prop still gets retried.
force_boot_prop "ro.boot.vbmeta.device_state" "locked"
force_boot_prop "ro.boot.verifiedbootstate" "green"
force_boot_prop "ro.boot.flash.locked" "1"
check_reset_prop "ro.boot.veritymode" "enforcing"
check_reset_prop "ro.boot.warranty_bit" "0"
check_reset_prop "ro.warranty_bit" "0"
check_reset_prop "ro.debuggable" "0"
check_reset_prop "ro.force.debuggable" "0"
check_reset_prop "ro.secure" "1"
check_reset_prop "ro.adb.secure" "1"
check_reset_prop "ro.build.type" "user"
check_reset_prop "ro.build.tags" "release-keys"
check_reset_prop "ro.vendor.boot.warranty_bit" "0"
check_reset_prop "ro.vendor.warranty_bit" "0"
check_reset_prop "vendor.boot.vbmeta.device_state" "locked"
check_reset_prop "vendor.boot.verifiedbootstate" "green"
check_reset_prop "sys.oem_unlock_allowed" "0"

# MIUI specific
check_reset_prop "ro.secureboot.lockstate" "locked"

# Realme specific
check_reset_prop "ro.boot.realmebootstate" "green"
check_reset_prop "ro.boot.realme.lockstate" "1"

# FS-Enhancer-Extreme passprop: crypto state must look encrypted on a locked device
check_reset_prop "ro.crypto.state" "encrypted"

# Hide that we booted from recovery when magisk is in recovery mode
contains_reset_prop "ro.bootmode" "recovery" "unknown"
contains_reset_prop "ro.boot.bootmode" "recovery" "unknown"
contains_reset_prop "vendor.boot.bootmode" "recovery" "unknown"

# Custom ROM (LineageOS) identity scrub: only fires when LOS-only signatures are present
v=$($RP ro.product.vendor.name)
case "$v" in
    lineage_*) $RP -n ro.product.vendor.name "${v#lineage_}" ;;
esac

v=$($RP vendor.camera.aux.packagelist)
case "$v" in
    *org.lineageos*) $RP -n vendor.camera.aux.packagelist "com.android.camera" ;;
esac

v=$($RP persist.vendor.camera.privapp.list)
case "$v" in
    *org.lineageos*) $RP -n persist.vendor.camera.privapp.list "com.android.camera" ;;
esac

[ -n "$($RP init.svc.vendor.lineage_health)" ] && {
    setprop ctl.stop vendor.lineage_health
    $RP -d init.svc.vendor.lineage_health
}

# Reset vbmeta related prop
empty_reset_prop "ro.boot.vbmeta.device_state" "locked"
empty_reset_prop "ro.boot.vbmeta.invalidate_on_error" "yes"
empty_reset_prop "ro.boot.vbmeta.avb_version" "1.0"
empty_reset_prop "ro.boot.vbmeta.hash_alg" "sha256"
empty_reset_prop "ro.boot.vbmeta.size" "4096"

$RP -c || true
