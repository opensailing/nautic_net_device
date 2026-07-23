# RacingOrg tracker

This is the parent/main repository for the "keelboat" tracker (aka "logger"). This is designed to run on a Raspberry Pi 3 b+ with SixFab LTE and a Pican-M hats.

__TODO:__ This repository used to support 2 products and is now designed only to support the keelboat variant. There is still cruft in here surrounding the "upload" variant that needs to be removed to be more hygenic.

Firmware is 64-bit (AArch64): the target system (`racing_org_system_rpi3` v3.0.0+)
runs the Pi 3's Cortex-A53 in 64-bit mode, which enables the Erlang/OTP JIT. The
system is consumed as a PREBUILT artifact from its GitHub release, and the
`aarch64-nerves-linux-gnu` cross toolchain ships macOS builds, so firmware
builds work directly on macOS (the old "Linux only" requirement is gone —
`:ng_can` cross-compiles against the Nerves system's kernel headers, not the
host's).

## Initial setup

* Install Erlang/OTP 28 and a matching Elixir (see `.tool-versions` /
  CI: Elixir 1.19, OTP 28).
* Install fwup (`brew install fwup` on macOS).
* Install Nerves bootstrap: `mix archive.install hex nerves_bootstrap`.
* Copy `.envrc-example` to `.envrc` and modify as needed. Then `direnv allow` to load the environment, answering the prompts.

During development the following are the command you should need:

```sh
# To get Nerves to compile for the rpi target
mix firmware

# To build and upload directly to SD card
mix firmware.burn

# To build and upload remotely
mix firmware && mix upload nerves.local
```

## Local development

If you need to work on the `racing_org_*` libraries locally, you can specify `RACING_ORG_DEPS_PATH='..'` and set up the
dependencies as sibling directories to this repo.

    racing_org_tracker/         <-- you are here
    racing_org_tracker_protobuf/
    racing_org_system_rpi3/
    nmea/
