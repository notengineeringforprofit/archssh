#!/bin/bash
# archssh manual Filen backup: one pass, /data/state -> /backups/archssh
# No timer, no dir watching. Run it when you want a commit.
# Safe to run concurrently (flock); writes last-backup on success.
#
# Consistency: the bb part is a `bb server export` archive (bb's built-in
# experimental server archive). It online-backups bb.db AND every plugin
# data.db, includes only server-owned files, and verifies every file with
# sha256 (manifest). If anything drifts mid-export the whole export is
# aborted — no partial or stale archive ever lands on Filen.
# Requires: bb server running (export is an RPC to it) and the serverMove
# experiment on (bb settings experiment serverMove true — stored in bb.db,
# so it survives the round-trip).
#
# The archive does NOT cover: pi state and plugin source dirs — those are
# rclone-copied alongside it. /data/filen-cli (Filen auth) is never backed
# up (chicken-and-egg restore dependency + trust model).
#
# Restore on a fresh box (Filen auth injected first):
#   filen --config-dir /data/filen-cli --skip-update rclone copy filen:backups/archssh/ /data/state/
#   bb server import /data/state/backup/bb-server.tar.gz --data-dir /data/state/bb --yes
#   bb server allow-connect --data-dir /data/state/bb
#   exec /data/start-bb.sh
exec 9>/data/filen-cli/backup.lock
flock 9

export PATH="/root/.local/bin:/root/.local/share/mise/installs/node/latest/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin"

FILIEN=/root/.filen-cli/bin/filen
LOG=/data/filen-cli/backup.log
EXPORT_DIR=/data/state/backup
EXPORT_FILE="$EXPORT_DIR/bb-server.tar.gz"
REMOTE=filen:backups/archssh

mkdir -p "$EXPORT_DIR"

# 1. bb server export: atomic, self-verifying server archive
bb server export --out "$EXPORT_FILE" --json 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
if [ "$rc" != "0" ]; then
  echo "ERROR: bb server export failed (rc=$rc) — bb server running? serverMove experiment on? — aborting" >> "$LOG"
  exit 1
fi
sha256sum "$EXPORT_FILE" >> "$LOG"

# 2. rclone copy: archive + pi state + plugin source (one-way, no --delete)
# --checksum: content-based sync — a same-size new export is never skipped
# because its mtime happened to match.
copy() {
  $FILIEN --config-dir /data/filen-cli --skip-update rclone copy --checksum "$@" -v 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]}
}
copy "$EXPORT_DIR" "$REMOTE/backup/" || { echo "ERROR: rclone copy backup/ failed — aborting" >> "$LOG"; exit 1; }
copy /data/state/pi "$REMOTE/pi/" || { echo "ERROR: rclone copy pi/ failed — aborting" >> "$LOG"; exit 1; }
copy /data/state/plugins "$REMOTE/plugins/" || { echo "ERROR: rclone copy plugins/ failed — aborting" >> "$LOG"; exit 1; }

# 3. timestamp
date +%s > /data/filen-cli/last-backup
echo "backup committed" >> "$LOG"
exit 0
