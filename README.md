# NauticNet device

This is the parent/main repository for the "keelboat" tracker (aka "logger"). This is designed to run on a Raspberry Pi 3 b+ with SixFab LTE and a Pican-M hats.

__TODO:__ This repository used to support 2 products and is now designed only to support the keelboat variant. There is still cruft in here surrounding the "upload" variant that needs to be removed to be more hygenic.

__When this library is used in a project it must be compiled on a Linux machine (physical or VM). This is due to the dependency on the linux kernel header files required to compile the CAN C driver. See the Development section of this document for further information.__

## Initial setup

This project requires that compiling is conducted on a Linux machine. This is due to the dependency on the linux kernel header files required to compile the CAN C driver in `:ng_can`.

The step to setup the machine are:

* Install Erlang otp 25
* Install precompiled Elixir 1.16.1 -- download precompiled and link into path.
* Install fwup via deb package found in fwup Github repo.
* Install Nerves (and dependencies).
* Create directories /Volumes/Nerves/dl and /Volumes/Nerves/artifacts with write permission for your user.
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

If you need to work on the `nautic_net_*` libraries locally, you can specify `NAUTIC_NET_DEPS_PATH='..'` and set up the
dependencies as sibling directories to this repo.

    nautic_net_device/         <-- you are here
    nautic_net_protobuf/
    nautic_net_system_rpi3/
    nmea/
