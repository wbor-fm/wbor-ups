# wbor-ups

## UPS Monitoring & Alerts

Automatically monitor UPS status using apcupsd on a Raspberry Pi, send email, GroupMe, Discord embed, and RabbitMQ notifications on power events (on/off).

## Overview

WBOR uses uninterrupted power supplies (UPS) to keep broadcast equipment powered during outages. Each UPS exposes status data (remaining battery life, health, load) via a COM port. We run [apcupsd](https://www.apcupsd.org/) on a Raspberry Pi to:

- **Trigger scripts** on power-loss (`onbattery`) and power-restore (`offbattery`) events
- **Send alerts** via:
  - Email (to station managers)
  - GroupMe bots (to management + clubwide channels)
  - Discord embeds (rich notifications -- also for members of management)
  - RabbitMQ messages (for integration with other services, using routing keys `notification.ups.onbattery`, `notification.ups.offbattery`, `notification.ups.fifteen`)

A follow-up alert is sent 15 minutes into power loss.

## Prerequisites

1. **Raspberry Pi** (any model with network & USB). Read this to see [how to put a Raspberry Pi on a campus (Wi-Fi) network](https://gist.github.com/mdrxy/ddb2ad2b958e5a3266d7cc05cf93c3e3), if needed.
2. **UPS with a COM/USB port.** Most do, but check the specs if unsure. (As indicated by the name, most APC brand UPSes have a COM port.)
3. **apcupsd**: [Info on installing & setting up](https://gist.github.com/mdrxy/462be21338a454c659b54d274fdc4456). Make sure to set your UPSNAME to something that helps you identify it if you have multiple UPSes. If installed correctly, you should be able to check the UPS status via the Pi's command line by running: `sudo apcaccess`
4. **msmtp** (for outbound email)
5. **curl** (for HTTP API calls). Raspbian almost always includes curl by default, but in case you need to install it, you can use: `sudo apt-get update && sudo apt-get install -y curl`
6. **Discord Webhook** for embed notifications. [Instructions here on how to set one up in your server's channel](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks).
7. **RabbitMQ Server**: A running instance of RabbitMQ. You'll need to ensure an exchange (e.g., a topic exchange) is set up for the messages.
8. **amqp-tools**: Command-line utilities for interacting with AMQP servers like RabbitMQ. Install on Debian/Ubuntu with:

    ```sh
    sudo apt-get update && sudo apt-get install -y amqp-tools
    ```

## Installation

1. Clone this repo onto your Pi:

    ```sh
    git clone https://github.com/wbor-fm/wbor-ups.git ~/wbor-ups
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
  APCUPSD_MAIL="msmtp"  # Mail transport agent

  # /etc/apcupsd/config
  # These are the new variables you need to set, add these lines to the file
  export UPSNAME="YOUR_UPS_NAME"  # Name of your UPS (mirror what is set in apcupsd.conf)
  export GROUPME_API_URL="https://api.groupme.com/v3/bots/post"
  export MGMT_BOT_ID="YOUR_MGMT_BOT_ID"
  export CLUBWIDE_BOT_ID="YOUR_CLUBWIDE_BOT_ID"
  export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/"
  export FROM_EMAIL="wbor-smtp@bowdoin.edu"  # Email sender address
  ```

By placing the exports in `/etc/apcupsd/config`, apcupsd will source them before invoking **onbattery**, **offbattery**, and **fifteen** scripts.

`msmtp` configuration is in `/etc/msmtprc`. Make sure to set the correct SMTP server, port, auth method, username, and password. Example config:

  ```bash
  sudo nano /etc/msmtprc
  ```

  ```text
  # /etc/msmtprc
  account        ACCOUNT_NAME_GOES_HERE
  host           ...
  port           587
  user           ...
  password       ...
  from           ...

  # make "ACCOUNT_NAME_GOES_HERE" the default account
  account default : ACCOUNT_NAME_GOES_HERE
  ```

## Scripts & Usage

- **onbattery**: This script runs when the UPS goes on battery (mains loss).
- **fifteen**: 15-minute follow-up script that runs on mains restoration
- **offbattery**: This script runs when the UPS goes back onto mains power (restoration).

All send email, GroupMe, Discord embeds, and RabbitMQ messages; `onbattery` schedules `fifteen`, and `offbattery` cancels it if still pending.

## Testing

You should **not** invoke the scripts directly with `sudo ./onbattery`, because that bypasses apccontrol's environment setup. Instead, use the apccontrol wrapper located in `/etc/apcupsd`:

  ```sh
  # Replace UPS-2 with your configured UPSNAME from apcupsd.conf
  sudo /etc/apcupsd/apccontrol onbattery UPS-2
  sudo /etc/apcupsd/apccontrol offbattery UPS-2
  ```

Check mail, GroupMe channels, your Discord webhook channel for embeds, and your RabbitMQ queues for messages.

If you prefer to call `apccontrol` directly, you can symlink it into a directory in your `sudo` secure_path:

```sh
sudo ln -s /etc/apcupsd/apccontrol /usr/local/sbin/apccontrol
```

Then you can simply run:

```sh
sudo apccontrol onbattery UPS-2
sudo apccontrol offbattery UPS-2
```

### Logs & Debugging

All hook‐scripts write to `/var/log/wbor-ups/*.log`, and apcupsd itself logs to `/var/log/apcupsd.events`. Use these commands to watch them in real time:

```sh
# Hook logs
sudo tail -f /var/log/wbor-ups/onbattery.log \
            /var/log/wbor-ups/fifteen.log \
            /var/log/wbor-ups/offbattery.log

# Core apcupsd events
sudo tail -f /var/log/apcupsd.events
```

If you're using msmtp, its log file is at `/var/log/msmtp.log` (make sure it's world-readable or sudo chown root:root), so:

```sh
sudo tail -f /var/log/msmtp.log
```

Debugging the 15-minute cancellation: In `offbattery.log` you'll already see lines like:

```sh
[2025-05-08 17:53:27] DEBUG: pidfile=/var/run/wbor-ups/fifteen.pid, exists? yes
[2025-05-08 17:53:27] DEBUG: post-cancel pidfile exists? no
```

If you don't see those, it means the `offbattery` hook either isn't running or is bailing out before that point. You can verify the hook ran:

```sh
ps aux | grep "[s]leep 900"      # should show the fifteen‐script sleeper
sudo grep cancel_fifteen /var/log/wbor-ups/offbattery.log
```

Dump the env apcupsd sees:

```sh
sudo /etc/apcupsd/apccontrol onbattery UPSNAME 2>&1 | tee ~/apcupsd_env_dump.txt
```

Check that $UPSNAME, $APCUPSD_MAIL, $RABBITMQ_URL, etc. are all set.
