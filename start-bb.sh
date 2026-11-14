#!/bin/bash
# Start the democracy bb server: durable state + pi harness under /data.
# Also used by the recreation bootstrap after a Filen restore.
# (Verbatim copy of /data/start-bb.sh on the box, baked 2026-11-14.)
export BB_DATA_DIR=/data/state/bb
export PI_CODING_AGENT_DIR=/data/state/pi/agent
export PATH="/root/.local/bin:/root/.local/share/mise/installs/node/latest/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin:/root/.filen-cli/bin"
exec /root/.local/share/mise/installs/node/latest/bin/bb-app --data-dir /data/state/bb >> /data/state/bb/server-stdout.log 2>&1
