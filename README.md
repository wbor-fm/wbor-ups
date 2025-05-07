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
    git clone https://github.com/WBOR-91-1-FM/wbor-ups.git /etc/apcupsd
    cd /etc/apcupsd
    ```

2. Enable & configure apcupsd following [these instructions](https://gist.github.com/mdrxy/462be21338a454c659b54d274fdc4456) if you haven't already.

3. Make scripts executable:

    ```sh
    sudo chmod +x onbattery offbattery fifteen discord_embed.sh groupme.sh
    ```

    apcupsd's config file is at `/etc/apcupsd/apcupsd.conf`, and `/etc/apcupsd/apccontrol` stores service config files that primarily handle app variables and logic that determines what script to run when an even occurs (such as mains power loss).

    We changed `SYSADMIN` to be our primary station email address and `APCUPSD_MAIL` to use "ssmtp", a program which delivers email from a local computer to a configured mailhost. In our case, we use our station-wide SMTP relay for Microsoft Office.

4. Follow [configuration](#configuration) instructions below to set up your environment variables.

## Configuration

In each UPS Pi's /etc/apcupsd/apccontrol (or globally in /etc/environment), set:

  ```sh
  export SYSADMIN="wbor@bowdoin.edu"  # Email recipient
  export APCUPSD_MAIL="ssmtp"  # Mail transport agent
  export GROUPME_API_URL="https://api.groupme.com/v3/bots/post"
  export MGMT_BOT_ID="YOUR_MGMT_BOT_ID"
  export CLUBWIDE_BOT_ID="YOUR_CLUBWIDE_BOT_ID"
  export DISCORD_WEBHOOK_URL="<https://discord.com/api/webhooks/…>"
  ```

If you are using msmtp, be sure to change the `APCUPSD_MAIL` variable to `msmtp` instead of `ssmtp`.

## Scripts & Usage

- **onbattery**: This script runs when the UPS goes on battery (mains loss).
- **fifteen**: 15-minute follow-up script that runs on mains restoration
- **offbattery**: This script runs when the UPS goes back onto mains power (restoration).

All send email, GroupMe, and Discord embeds; `onbattery` schedules `fifteen`, and `offbattery` cancels it if still pending.

## Testing

Manually invoke your scripts to verify:

  ```sh
  cd /etc/apcupsd
  sudo ./onbattery    # simulate loss
  sudo ./offbattery   # simulate restore
  ```

Check mail, GroupMe channels, and your Discord webhook channel for embeds.
