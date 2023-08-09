# NauticNet device

NMEA2000 device.

## Initial setup

On macOS, make an APFS case-sensitive volume called "Nerves". This is important because case sensitivity matters, and APFS is case-insensitive by default.

Go to https://github.com/DockYard/nautic_net_system_rpi3/releases/ and download the latest release .tar.gz package. Move it into `/Volumes/Nerves/dl`.

```
# Nerves dependencies (https://hexdocs.pm/nerves/installation.html)
brew install fwup squashfs coreutils xz pkg-config

# Install Elixir
asdf install

# Set up Nerves
mix archive.install hex nerves_bootstrap

# Get the stuff
mix deps.get
```

Copy `.envrc-example` to `.envrc` and modify as needed. Then `direnv allow` to load the environment, answering the prompts.

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
    nautic_net_nmea2000/
    nautic_net_protobuf/
    nautic_net_system_rpi3/
