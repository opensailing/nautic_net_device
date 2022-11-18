# NauticNet device

NMEA2000 device.

## Initial setup

Copy `.envrc-example` to `.envrc` and modify as needed. Then `direnv allow` to load the environment.

```sh
export MIX_TARGET=nautic_net_rpi2

# To get Nerves to compile for the rpi target
mix firmware

# To build and upload directly to SD card
mix firmware.burn

# To build and upload remotely
mix firmware && mix upload nerves.local
```
