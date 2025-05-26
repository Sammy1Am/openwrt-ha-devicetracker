# OpenWRT Home Assistant Device Tracker Shell Script
### A service for OpenWRT to integrate with Home Assistant Device Tracker

Although Home Assistant already has [an official ubus integration](https://www.home-assistant.io/integrations/ubus/), I preferred the push-model offered by [rmoesbergen/openwrt-ha-device-tracker](https://github.com/rmoesbergen/openwrt-ha-device-tracker).  However sometime in the last version(s?) the OpenWRT Python packages have become too large for my access point and I needed something smaller.  This script/service should only require the `jq` package on top of what is already present in a standard OpenWRT install.

**Disclosure**: I utilized the Gemini LLM to get this project started quickly, but its suggestion needed a fair bit of debugging. I've looked through the code and I don't personally see anything suspicious and I have confirmed that it's working well on my home network; but caveat lector nonetheless.

## Setup
1. Use `opkg` to install `jq` (other dependencies should hopefully already be included)
1. Copy each of the three files to its appropriate location on your OpenWRT AP:
    - `bin/ha_device_tracker.sh` to `/usr/bin/` (or wherever you prefer— the init.d script will need to be updated if choose a different location)
    - `config/ha_device_tracker` to `/etc/config`
    - `init.d/ha_device_tracker` to `/etc/init.d`
1. `chmod +x` the `bin` and `init.d` files.
1. Update the config file with:
    - The base URL and port for your Home Assistant instance
    - An API token for your Home Assistant instance
    - The MAC address and device name for each of the devices you'd like to track.
1. Run `/etc/init.d/ha_device_tracker enable` to enable the service and `/etc/init.d/ha_device_tracker start` to start it.

## Additional Notes
- You can enable debug logging in the config file to get some output in the syslog which might be helpful for troubleshooting.
- It's not strictly necessary (I don't think) to filter the devices by MAC address.  This script could be modified to report *all* associations and disassociations for an AP.
- There is not currently a periodic-check component of this service. This means if a device connects or disconnected while either the service or HA are not running, its status will not be properly updated. Would like to eventually add that though; PRs welcome!
