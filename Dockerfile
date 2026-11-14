# ============================================================================
# archssh — bb server + pi harness, reproducible rootfs
#
# Baked 2026-11-14 from the live box. Every version is pinned to what is
# verified running on the box; a re-bake re-pins against the live box, never
# against "latest".
#
#   tool        pin           source (verified)
#   ----------  -----------   ----------------------------------------------
#   Arch base   base-20261110.0.623834
#                       quay.io tag — the app's current base. The image then
#                       full-upgrades to the live repos at build time (the
#                       live spec does the same at boot), landing on:
#   git         2.56.1        pacman (box version)
#   sqlite      3.54.1        pacman (box version)
#   openssh     10.6p1        pacman (box version, PQC kex/auth)
#   openssl     4.1.0         pacman (box version)
#   mise        2026.11.7     GitHub release (same as the box)
#   node        26.13.1       mise pin (box had "latest"; pinned here so a
#                             rebuild can never drift)
#   pi          1.5.2         npm global @earendil-works/pi-coding-agent
#   bb          0.49.0        npm global bb-app
#   filen-cli   0.2.9         FilenCloudDienste release; sha256
#                             a86b22a2d0f0f32cf4ff24113dbf57fc274d85bbc83f42f9f4c248a1767aca29
#                             = byte-identical to the laptop's working 0.2.9
#
# What is deliberately NOT in this image:
#   - Filen auth: deploy-time secret, injected from the phone over SSH into
#     /data/filen-cli (E2EE flow; never baked into image or spec)
#   - bb data dir: restored from Filen — backup/bb-server.tar.gz
#     (a `bb server export` archive) via `bb server import`
#   - pi harness: restored from Filen — pi/ (radeon extension, auth, models)
#   - plugin source: restored from Filen — plugins/
#
# Layout contract: /data is a host-mounted volume (r:/data). Anything baked
# into the image at /data would be hidden by that mount, so the scripts live
# in the image at /usr/local and the entrypoint materializes
# /data/start-bb.sh from them on first boot (idempotent: an existing
# /data/start-bb.sh — e.g. from a Filen restore or a previous boot — is
# kept).
#
# Entry:
#   - docker run: ENTRYPOINT /usr/local/bootstrap.sh (for local testing)
#   - on Flux: the spec's commands field OVERRIDES the image entrypoint
#     (containerd uses spec commands as the container entrypoint). The new
#     spec command is:  sh -c /usr/local/bootstrap.sh
#     (kept in the embedded sh -c form so spec re-creation is stable —
#     see the F_S_CMD gotcha from the original archssh bootstrap)
#
# Local smoke test (laptop):
#   docker build -t archssh-image .
#   docker run --rm -v /tmp/archssh-data:/data archssh-image
#     → expect: sshd starts, bootstrap waits for Filen auth, no crash loop
#
# bootstrap.sh:
#   1. generate SSH host keys (openssh package doesn't — the old spec ran
#      ssh-keygen -A at boot), install the Flux-managed SSH key (public
#      on-chain; same line as the original archssh spec), start sshd
#      (exit 1 if it fails — Flux restart ladder retries)
#   2. materialize the known-tool scripts (idempotent): /data/start-bb.sh
#      and /data/filen-cli/backup-once.sh. The latter lives in /data/filen-cli,
#      which is NOT in the Filen backup (deploy-time layer) — so a fresh
#      restore would otherwise leave the box without its backup tool.
#   3. if /data/state/bb/bb.db exists: exec /data/start-bb.sh
#      (recreation case — /data survived, nothing to restore)
#   4. otherwise: wait for /data/filen-cli/filen-cli-auth-config.txt
#      (phone injects it over SSH), pull backup/ pi/ plugins/ from Filen,
#      `bb server import` the archive, `bb server allow-connect`, then
#      exec /data/start-bb.sh
# ============================================================================

FROM quay.io/archlinux/archlinux:base-20261110.0.623834

# ---------------------------------------------------------------- packages
# The base tag is a FIXED snapshot (20261110), but `pacman -Sy` reads the
# LIVE repos, where openssl has jumped 3 -> 4 — installing against the live
# repos breaks the snapshot's own dependents (libcrypto.so=3).
#
# The live spec solves exactly this at boot: `pacman-key --init --populate
# archlinux; pacman -Syu ...` (a FULL system upgrade). We mirror that here,
# moved from boot-time into the image, so the container boots into the same
# working state the box already runs (openssl 4.1.0, git 2.56.1, sqlite
# 3.54.1, openssh 10.6p1). `-Syu` upgrades the whole rootfs to current and
# installs the named packages in one consistent transaction.
#   git/openssh/curl: SSH entry point + key bootstrap + plugin dev
#   sqlite:           DB inspection during phone-led rescues
#   rsync:            general-purpose file moves during rescue work
#   unzip:            build-time only, for the mise tarball
# Note: the spec's boot line `pacman-key --init --populate archlinux` actually
# errors ("Multiple operations specified") and its `;` separator let boot
# continue — proof the base image ships a working keyring. We keep the steps
# (separately, lenient) as a guard for future base tags; `pacman -Syu`
# signature verification is the real gate.
RUN (pacman-key --init || true) \
    && (pacman-key --populate archlinux || true) \
    && pacman -Syu --noconfirm git sqlite rsync openssh curl unzip \
    && rm -rf /var/lib/pacman/db.lck /var/cache/pacman/pkg/*

# ---------------------------------------------------------------- mise
# Pinned standalone binary to /root/.local/bin/mise — the exact location the
# box uses (so /data/start-bb.sh PATH works unchanged).
ARG MISE_VERSION=2026.11.7
RUN set -eux \
    && mkdir -p /root/.local/bin \
    && curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64.tar.gz" -o /tmp/mise.tar.gz \
    && tar -xzf /tmp/mise.tar.gz -C /tmp \
    && install -m 755 /tmp/mise/bin/mise /root/.local/bin/mise \
    && rm -rf /tmp/mise.tar.gz /tmp/mise \
    && /root/.local/bin/mise --version

# ---------------------------------------------------------------- node
# Exact pin. `mise use -g` writes the global config and installs the toolchain.
RUN /root/.local/bin/mise use -g node@26.13.1

# ---------------------------------------------------------------- pi + bb
# npm globals under the pinned node, box versions. The bins (pi, bb, bb-app,
# node, npm, npx) land in the node install's bin/ dir — mise auto-creates the
# `latest` symlink (installs/node/latest -> 26.13.1), which is what
# start-bb.sh's PATH relies on. /root/.local/bin is included so mise's npm
# reshim wrapper can find `mise` during the install.
ENV PATH="/root/.local/share/mise/installs/node/latest/bin:/root/.local/share/mise/shims:/root/.local/bin:${PATH}"
RUN set -eux \
    && npm install -g @earendil-works/pi-coding-agent@1.5.2 bb-app@0.49.0 \
    && node --version \
    && pi --version \
    && bb --version \
    && ls /root/.local/share/mise/installs/node/latest/bin/

# ---------------------------------------------------------------- filen-cli
# Pinned release binary, sha256-verified against the laptop's working 0.2.9.
# Same layout as the box: /root/.filen-cli/bin/filen.
# Note: filen-cli's managed rclone is downloaded on first use into its config
# area; that is the only restore-path network dependency, which is fine
# (Filen requires network anyway).
RUN set -eux \
    && mkdir -p /root/.filen-cli/bin \
    && curl -fsSL "https://github.com/FilenCloudDienste/filen-cli-releases/releases/download/0.2.9/filen-cli-0.2.9-x86_64-unknown-linux-gnu" -o /root/.filen-cli/bin/filen \
    && echo "a86b22a2d0f0f32cf4ff24113dbf57fc274d85bbc83f42f9f4c248a1767aca29  /root/.filen-cli/bin/filen" | sha256sum -c - \
    && chmod 755 /root/.filen-cli/bin/filen \
    && /root/.filen-cli/bin/filen --version

# ---------------------------------------------------------------- scripts
# start-bb.sh:        the bb server launcher (bootstrap materializes to /data)
# backup-once.sh:     the manual Filen backup (bootstrap materializes to
#                     /data/filen-cli — a known tool, not user data)
# bootstrap.sh:       the entrypoint (runs as PID 1 on every new container)
COPY start-bb.sh    /usr/local/start-bb.sh
COPY backup-once.sh /usr/local/backup-once.sh
COPY bootstrap.sh   /usr/local/bootstrap.sh
RUN chmod +x /usr/local/start-bb.sh /usr/local/backup-once.sh /usr/local/bootstrap.sh

ENTRYPOINT ["/usr/local/bootstrap.sh"]
