# archssh image

Reproducible rootfs for the `archssh` Flux Cloud app: a headless BB server
(`democracy.getbb.app`) + pi harness, with Filen as the durable state layer.

Bake: `docker build -t archssh:dev .` → tag immutable (`YYYY.MM.DD-N`) →
push to `ghcr.io/notengineeringforprofit/archssh` → point the Flux app spec
at the tag and redeploy the component.

See the Dockerfile header for the full pin table and restore contract.
