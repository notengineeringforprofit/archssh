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
# The archive does NOT cover: pi state, plugin source dirs, and the machine
# identity files — those are rclone-copied alongside it. /data/filen-cli
# (Filen auth) is never backed up (chicken-and-egg restore dependency +
# trust model).
#
# Machine identity pin: host-id + auth.json are the box-side half of the
# machine identity. The server-side half (the apikey row in bb.db, hashed
# with sha256/base64url) is inside the export archive. Backing both up in
# the same pass means a hard reset + restore brings the box back as the
# SAME machine: the daemon finds host-id (reuses the hostId, no new UUID),
# finds auth.json (skips re-enrollment), and its hostKey validates against
# the restored apikey row. No orphan archssh machine records accumulate.
#
# Restore on a fresh box (Filen auth injected first):
#   filen --config-dir /data/filen-cli --skip-update rclone copy filen:backups/archssh/ /data/state/
#   bb server import /data/state/backup/bb-server.tar.gz --data-dir /data/state/bb --yes
#   bb server allow-connect --data-dir /data/state/bb
#   exec /data/start-bb.sh
# The rclone line also restores bb/host-id + bb/auth.json into /data/state/bb/
# (before the import; import does not touch them).
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

# 3. machine identity pin: host-id + auth.json only (NOT the whole bb dir —
# bb.db/wal/shm, daemon.lock, logs are runtime state covered by the archive).
# auth.json holds the daemon bearer key — a secret, but the same trust domain
# as the rest of this backup (E2EE on Filen; the archive already carries the
# full bb.db).
copy /data/state/bb "$REMOTE/bb/" --include host-id --include auth.json || { echo "ERROR: rclone copy bb/ identity failed — aborting" >> "$LOG"; exit 1; }

# 4. timestamp
date +%s > /data/filen-cli/last-backup
echo "backup committed" >> "$LOG"
exit 0
