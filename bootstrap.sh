#!/bin/bash
# ============================================================================
# archssh bootstrap — runs as PID 1 of every new container.
#
#   1. Installs the Flux-managed SSH key (public on-chain; the same line the
#      original archssh spec used) and starts sshd, so the phone can reach
#      the box on any new node from the first boot.
#   2. If /data/state/bb/bb.db exists: /data survived (hard reset /
#      redeploy). Just start the server.
#   3. Otherwise: /data is fresh (new node). Wait for the phone to inject
#      the Filen auth config over SSH, restore state from Filen, import the
#      bb server archive, and start.
#
# Filen auth is the ONLY deploy-time secret. Everything else (bb pairing
# via auth-secret, radeon key via pi/auth.json, plugin state) lives in the
# Filen backup and comes back with it.
# ============================================================================
set -u

PATH="/root/.local/bin:/root/.local/share/mise/installs/node/latest/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin:/root/.filen-cli/bin"
export PATH

FLUX_KEY_URL="https://storage.runonflux.io/v1/public/041482124884630"
FILEN_DIR=/data/filen-cli
FILEN_AUTH="$FILEN_DIR/filen-cli-auth-config.txt"
FILEN_BIN=/root/.filen-cli/bin/filen
STATE=/data/state
BB_DIR=$STATE/bb
REMOTE=filen:backups/archssh
LOG=/data/bootstrap.log

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# --- 1. SSH entry point ----------------------------------------------------
mkdir -p /run/sshd /root/.ssh
# The openssh package does NOT generate host keys at install time (the old
# spec ran ssh-keygen -A at boot for exactly this reason). Idempotent: any
# existing keys are kept. Keys regenerate on each container recreation —
# same behavior as the old spec (clear stale known_hosts before SSH).
ssh-keygen -A
curl -fsS "$FLUX_KEY_URL" | tr -d '"' > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
if ! /usr/sbin/sshd -E /data/sshd.log; then
  log "ERROR: sshd failed to start — see /data/sshd.log"
  exit 1
fi
log "sshd started"

# Materialize the canonical start script (idempotent: a file restored from
# Filen or written on a previous boot wins).
if [ ! -f /data/start-bb.sh ]; then
  install -m 755 /usr/local/start-bb.sh /data/start-bb.sh
fi

# --- 2. /data survived ------------------------------------------------------
if [ -f "$BB_DIR/bb.db" ]; then
  log "existing bb state at $BB_DIR — starting (no restore needed)"
  exec /data/start-bb.sh
fi

# --- 3. Fresh /data: wait for Filen auth, restore, start --------------------
log "fresh /data — waiting for Filen auth at $FILEN_AUTH (inject from phone over SSH)"
while [ ! -f "$FILEN_AUTH" ]; do sleep 15; done
log "Filen auth present — restoring state from $REMOTE"

mkdir -p "$FILEN_DIR" "$STATE"
if ! "$FILEN_BIN" --config-dir "$FILEN_DIR" --skip-update \
      rclone copy "$REMOTE" "$STATE/" -v >>"$LOG" 2>&1; then
  log "ERROR: Filen restore (rclone copy) failed — exiting, Flux will restart"
  exit 1
fi
log "state restored from Filen"

# Import the bb server archive into the (pristine) data dir.
if [ ! -f "$STATE/backup/bb-server.tar.gz" ]; then
  log "ERROR: $STATE/backup/bb-server.tar.gz missing after restore — exiting"
  exit 1
fi
mkdir -p "$BB_DIR"
if ! bb server import "$STATE/backup/bb-server.tar.gz" --data-dir "$BB_DIR" --yes >>"$LOG" 2>&1; then
  # Loud, common pre-condition: import refuses any data dir that still has
  # server data (bb.db or its -wal/-shm). This happens if a previous-gen
  # tree was restored into $BB_DIR. The archive is authoritative — remove
  # the stale DB files, then re-run.
  if [ -f "$BB_DIR/bb.db" ]; then
    log "ERROR: import refused — stale server data in $BB_DIR (bb.db exists). Remove $BB_DIR/bb.db* (archive is authoritative), then re-run bootstrap."
  else
    log "ERROR: bb server import failed (bb version too old for the archive?) — see $LOG"
  fi
  exit 1
fi
log "bb server archive imported"

# Re-enable the bb connect tunnel (import holds it until explicitly allowed).
# Local file operation — does not call a server.
if ! bb server allow-connect --data-dir "$BB_DIR" --yes >>"$LOG" 2>&1; then
  log "ERROR: bb server allow-connect failed — exiting"
  exit 1
fi

# NOTE: no plugin reinstall step needed — the archive carries the built
# runtime plugin bundles (plugins/runtime/...), so the server loads them on
# startup. /data/state/plugins holds the source dirs (also restored above)
# for future `bb plugin build` cycles.

log "bootstrap complete — starting bb server"
exec /data/start-bb.sh
