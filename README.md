# wbor-ups

## UPS Monitoring & Alerts

Automatically monitor UPS status using apcupsd on a Raspberry Pi, send email, GroupMe, and Discord embed notifications on power events (on/off).

## Overview

WBOR uses uninterrupted power supplies (UPS) to keep broadcast equipment powered during outages. Each UPS exposes status data (remaining battery life, health, load) via a COM port. We run [apcupsd](https://www.apcupsd.org/) on a Raspberry Pi to:

- **Trigger scripts** on power-loss (`onbattery`) and power-restore (`offbattery`) events  
- **Send alerts** via:
  - Email (to station managers)  
  - GroupMe bots (to management + clubwide channels)  
  - Discord embeds (rich notifications -- also for members of management)

A follow-up alert is sent 15 minutes into power loss.

## Prerequisites

1. **Raspberry Pi** (any model with network & USB). Read this to see [how to put a Raspberry Pi on a campus (Wi-Fi) network](https://gist.github.com/mdrxy/ddb2ad2b958e5a3266d7cc05cf93c3e3), if needed.
2. **UPS with a COM/USB port.** Most do, but check the specs if unsure. (As indicated by the name, most APC brand UPSes have a COM port.)
3. **apcupsd**: [Info on installing & setting up](https://gist.github.com/mdrxy/462be21338a454c659b54d274fdc4456). Make sure to set your UPSNAME to something that helps you identify it if you have multiple UPSes. If installed correctly, you should be able to check the UPS status via the Pi's command line by running: `sudo apcaccess`
4. **ssmtp or msmtp** (for outbound email)
5. **curl** (for HTTP API calls). Raspbian almost always includes curl by default, but in case you need to install it, you can use: `sudo apt-get update && sudo apt-get install -y curl`
6. **Discord Webhook** for embed notifications. [Instructions here on how to set one up in your server's channel](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks).

## Installation

1. Clone this repo onto your Pi:

    ```sh
    git clone https://github.com/WBOR-91-1-FM/wbor-ups.git ~/wbor-ups
    ```

2. Enable & configure apcupsd following [these instructions](https://gist.github.com/mdrxy/462be21338a454c659b54d274fdc4456) if you haven't already.

3. Install scripts and make them executable:

    ```sh
    cd ~/wbor-ups
    sudo chmod +x onbattery offbattery fifteen discord_embed.sh groupme.sh common.sh
    sudo cp onbattery offbattery fifteen discord_embed.sh groupme.sh common.sh /etc/apcupsd/
    ```

    apcupsd's config file is at `/etc/apcupsd/apcupsd.conf`, and `/etc/apcupsd/apccontrol` stores service config files that primarily handle app variables and logic that determines what script to run when an even occurs (such as mains power loss).

4. Follow [configuration](#configuration) instructions below to set up your environment variables.

## Configuration

In each UPS Pi's `/etc/apcupsd/apccontrol` and `/etc/apcupsd/config`, set the following environment variables:

  ```sh
  # /etc/apcupsd/apccontrol
  # These exist by default, but you may want to change them
  SYSADMIN="wbor@bowdoin.edu"  # Email recipient
  APCUPSD_MAIL="ssmtp"  # Mail transport agent

  # /etc/apcupsd/config
  # These are the new variables you need to set, add these lines to the file
  export UPSNAME="YOUR_UPS_NAME"  # Name of your UPS (mirror what is set in apcupsd.conf)
  export GROUPME_API_URL="https://api.groupme.com/v3/bots/post"
  export MGMT_BOT_ID="YOUR_MGMT_BOT_ID"
  export CLUBWIDE_BOT_ID="YOUR_CLUBWIDE_BOT_ID"
  export DISCORD_WEBHOOK_URL="<https://discord.com/api/webhooks/…>"
  export FROM_EMAIL="wbor-smtp@bowdoin.edu"  # Email sender address
  ```

By placing the exports in `/etc/apcupsd/config`, apcupsd will source them before invoking **onbattery**, **offbattery**, and **fifteen** scripts.

If you are using msmtp, be sure to change the `APCUPSD_MAIL` variable to `msmtp` instead of `ssmtp`.

## Scripts & Usage

- **onbattery**: This script runs when the UPS goes on battery (mains loss).
- **fifteen**: 15-minute follow-up script that runs on mains restoration
- **offbattery**: This script runs when the UPS goes back onto mains power (restoration).

All send email, GroupMe, and Discord embeds; `onbattery` schedules `fifteen`, and `offbattery` cancels it if still pending.

## Testing

You should **not** invoke the scripts directly with `sudo ./onbattery`, because that bypasses apccontrol's environment setup. Instead, use the apccontrol wrapper located in `/etc/apcupsd`:

  ```sh
  # Replace UPS-2 with your configured UPSNAME from apcupsd.conf
  sudo /etc/apcupsd/apccontrol onbattery UPS-2
  sudo /etc/apcupsd/apccontrol offbattery UPS-2
  ```

Check mail, GroupMe channels, and your Discord webhook channel for embeds.

If you prefer to call `apccontrol` directly, you can symlink it into a directory in your `sudo` secure_path:

```sh
sudo ln -s /etc/apcupsd/apccontrol /usr/local/sbin/apccontrol
```

Then you can simply run:

```sh
sudo apccontrol onbattery UPS-2
sudo apccontrol offbattery UPS-2
```
