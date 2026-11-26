# WiFi access point mode

By default (`WIFI_MODE="ap"`) the dongle comes up as a WiFi access point on
first boot:

- SSID: `OpenStick`
- Security: WPA2-PSK, password `12345678`
- Band/channel: 2.4 GHz 802.11bg, channel 1
- Device address: `192.168.43.1/24` on wlan0
- DHCP/DNS for clients: NetworkManager "shared" mode (dnsmasq) on
  192.168.43.0/24

So after flashing you can join the `OpenStick` network (password
`12345678`) and reach the device at `192.168.43.1` (e.g.
`ssh user@192.168.43.1`). The USB gadget network is unchanged: the device
stays reachable at `192.168.42.1` over USB (`USB0_IP`).

## Client mode

Set `WIFI_MODE="client"` (and `WIFI_SSID`/`WIFI_PASS`) to restore the
previous behavior: the dongle joins an existing network as a station and
gets its address via DHCP (or the static `WIFI_IP`/`WIFI_GW`/`WIFI_DNS`).

Set `WIFI_ENABLED="no"` to ship no wlan connection at all.

## Limitations

- The wcn36xx (WCNSS) firmware cannot run a station and an access point at
  the same time — STA+AP simultaneously is not supported (per the aipmy
  README), so the WiFi radio is either the AP or a client, never both.
- `12345678` is a well-known default password, the same on every image.
  Change it on the device in
  `/etc/NetworkManager/system-connections/wlan.nmconnection` if the AP is
  used anywhere other than a trusted bench network.
