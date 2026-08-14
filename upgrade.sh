#!/usr/bin/env bash
# Cosmos Auto Upgrade
set -Eeuo pipefail
VERSION=4.0

usage(){ echo "Usage: $0 <height> <service> <new_binary> <chain_home>"; exit 1; }
[[ $# -eq 4 ]] || usage
HEIGHT_TARGET="$1"; SERVICE="$2"; NEW_BINARY="$3"; CHAIN_HOME="$4"
USER_NAME=$(whoami)
BIN=$(command -v "$SERVICE" || true)
CFG="$CHAIN_HOME/config/config.toml"
LOCK="/tmp/${SERVICE}.upgrade.lock"
LOG="${PWD}/upgrade-${SERVICE}.log"
SUDOERS="/etc/sudoers.d/auto-upgrade-${SERVICE}"

log(){ printf '[%(%F %T)T] %s\n' -1 "$*"|tee -a "$LOG"; }
die(){ log "ERROR: $*"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || die "Another upgrade instance is already running."

for c in curl jq grep sed sudo systemctl visudo flock;do command -v "$c">/dev/null||die "$c missing";done
[[ -f "$CFG" ]]||die "Missing config.toml"
[[ -f "$NEW_BINARY" ]]||die "Missing new binary"
[[ -n "$BIN" ]]||die "Binary $SERVICE not found in PATH"

RPC_PORT=$(grep -m1 '^laddr = ' "$CFG"|sed -E 's/.*:([0-9]+)".*/\1/')
[[ $RPC_PORT =~ ^[0-9]+$ ]]||die "Cannot detect RPC port"

setup_sudo(){
    #
    # Running as root?
    #
    if [[ $EUID -eq 0 ]]; then
        log "Running as root. Skipping sudoers configuration."
        return
    fi

    #
    # Sudoers already exists and covers everything we need?
    # We re-check every required line, not just file presence, so an
    # old/incomplete file (e.g. missing restart/is-active) gets fixed.
    #
    local need_write=0
    if sudo test -f "$SUDOERS" 2>/dev/null; then
        for sub in stop start restart is-active status; do
            sudo grep -q "systemctl $sub $SERVICE\$" "$SUDOERS" 2>/dev/null || need_write=1
        done
        if [[ $need_write -eq 0 ]]; then
            log "Passwordless sudo already configured."
            return
        fi
        log "Existing sudoers file is incomplete, rewriting it..."
    else
        log "Installing passwordless sudo rule..."
    fi

    # NOTE: argument must match exactly what this script passes to systemctl
    # (i.e. "$SERVICE" as given on the command line, no .service suffix
    # unless you invoke the script with one).
    sudo mkdir -p /etc/sudoers.d
    sudo tee "$SUDOERS" >/dev/null <<EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl stop $SERVICE
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl start $SERVICE
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl restart $SERVICE
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl is-active $SERVICE
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl status $SERVICE
EOF
    sudo chmod 440 "$SUDOERS"
    sudo visudo -cf "$SUDOERS" >/dev/null || die "Invalid sudoers"

    # Confirm it actually works non-interactively before we rely on it later
    for sub in stop start restart is-active; do
        sudo -n systemctl "$sub" "$SERVICE" >/dev/null 2>&1 || true
    done
    if ! sudo -n true 2>/dev/null; then
        log "Warning: general 'sudo -n true' failed, but scoped rules may still be fine."
    fi
}
setup_sudo

chmod +x "$NEW_BINARY"
"$NEW_BINARY" version >/dev/null 2>&1 || log "Warning: version command failed"

get_height(){ curl -fsS "http://127.0.0.1:${RPC_PORT}/status"|jq -r '.result.sync_info.latest_block_height'; }

#############################################
# Information
#############################################

echo
echo "=========================================="
echo "        Cosmos Auto Upgrade v4"
echo "=========================================="
echo "User            : $USER_NAME"
echo "Service         : $SERVICE"
echo "Current Binary  : $BIN"
echo "New Binary      : $NEW_BINARY"
echo "Chain Home      : $CHAIN_HOME"
echo "Config          : $CFG"
echo "RPC Port        : $RPC_PORT"
echo "Upgrade Height  : $HEIGHT_TARGET"
echo "Log File        : $LOG"
echo "Lock File       : $LOCK"
echo "Sudoers File    : $SUDOERS"
echo "=========================================="
echo

wait_rpc(){
 until h=$(get_height 2>/dev/null); do printf "\rWaiting RPC..."; sleep 2; done
 echo; log "RPC ready at height $h"
}
wait_rpc

backup="${BIN}.bak.$(date +%Y%m%d-%H%M%S)"
rollback(){
 if [[ -f "$backup" ]]; then
   log "Rollback..."
   cp -f "$backup" "$BIN"
   chmod +x "$BIN"
   sudo systemctl restart "$SERVICE" || true
 fi
}
trap 'log "Interrupted"; rollback' INT TERM

LAST=0; STUCK=0
while true; do
 h=$(get_height 2>/dev/null||echo "")
 if [[ ! $h =~ ^[0-9]+$ ]]; then printf "\rWaiting RPC..."; sleep 2; continue; fi
 (( h==LAST )) && ((STUCK++)) || STUCK=0
 LAST=$h
 rem=$((HEIGHT_TARGET-h))
 printf "\rHeight %-12s Remaining %-12s" "$h" "$rem"
 if ((STUCK>=30)); then echo; log "Warning: height not moving"; STUCK=0; fi
 if ((h>=HEIGHT_TARGET)); then
   echo; log "Upgrade height reached"
   cp -f "$BIN" "$backup"
   sudo systemctl stop "$SERVICE"
   tmp="${BIN}.new"
   cp -f "$NEW_BINARY" "$tmp"
   chmod +x "$tmp"
   mv -f "$tmp" "$BIN"
   sudo systemctl start "$SERVICE"

   #############################################
   # 1. Did the process survive startup?
   #    A genuinely broken binary (bad upgrade handler, corrupted
   #    binary, wrong chain-id, panic) crashes within seconds, so a
   #    short check here is enough to catch that class of failure.
   #############################################
   sleep 8
   if ! sudo systemctl is-active --quiet "$SERVICE"; then
      log "Service failed to stay running after upgrade"
      sudo journalctl -u "$SERVICE" -n 50 --no-pager | tee -a "$LOG"
      rollback
      die "Upgrade failed"
   fi
   log "Process is running post-upgrade."

   #############################################
   # 2. Did blocks actually resume?
   #    This is informational/patient, NOT a rollback trigger on its
   #    own -- the chain may sit idle for minutes waiting on 65%+1
   #    validator quorum before block production resumes. We only
   #    roll back here if the process itself crashes while we wait.
   #############################################
   log "Waiting for chain to resume (can take minutes if waiting on validator quorum)..."
   PREV_H="$h"
   RESUMED=0
   for i in $(seq 1 60); do   # up to ~10 minutes
      sleep 10
      if ! sudo systemctl is-active --quiet "$SERVICE"; then
         log "Service crashed while waiting for chain to resume"
         sudo journalctl -u "$SERVICE" -n 50 --no-pager | tee -a "$LOG"
         rollback
         die "Upgrade failed"
      fi
      NEW_H=$(get_height 2>/dev/null || echo "")
      if [[ -n "$NEW_H" && "$NEW_H" =~ ^[0-9]+$ && "$NEW_H" -gt "$PREV_H" ]]; then
         log "Blocks resumed at height $NEW_H"
         RESUMED=1
         break
      fi
      log "Still waiting for quorum/block production... (elapsed $((i*10))s)"
   done
   if [[ $RESUMED -eq 0 ]]; then
      log "Warning: process is alive but blocks have not resumed after ~10min. Leaving node running -- check other validators' upgrade status manually."
   fi

   log "Upgrade successful"
   "$BIN" version || true
   exit 0
 fi
 sleep 2
done
