# wbor-ups

Bowdoin faces regular power outages. As a result, we currently have three uninterrupted power supplies (UPS) feeding our broadcast equipment. A common feature of these devices is a communication port that outputs their statuses, including information about battery time remaining, health, and more. Using Raspberry Pi microcomputers running [apcupsd](https://www.apcupsd.org/), we're able to send messages remotely to station managers + view UPS status using an online dashboard.

* [Info on setting up apcupsd](https://gist.github.com/mdrxy/462be21338a454c659b54d274fdc4456)

  * Make sure to set UPSNAME to something that helps you identify it in the studio.

* [How to put a Raspberry Pi on a campus network](https://gist.github.com/mdrxy/ddb2ad2b958e5a3266d7cc05cf93c3e3)

To check the UPS status via the Pi’s command line, run:

```sh
sudo apcaccess
```

apcupsd config files are stored at `/etc/apcupsd/apcupsd.conf`, and `/etc/apcupsd/apccontrol` stores service config files that primarily handle app variables and logic that determines what script to run when an even occurs (such as mains power loss). We changed `SYSADMIN` to be our primary station email and `APCUPSD_MAIL` to use "ssmtp", a program which delivers email from a local computer to a configured mailhost. In our case, we use our station-wide SMTP relay for Microsoft Office, which is what Bowdoin uses.

ssmtp needs to be installed on new devices by running `sudo apt-get install ssmtp`. Its config is located at `/etc/ssmtp/ssmtp.conf` and must be configured with the relevant credentials.

The primary events we’re concerned with is power loss and restoration, so we have added to the `onbattery`/`offbattery` scripts at `/etc/apcupsd/`. These send an email and message to our GroupMe group of station managers. `onbattery` includes the estimated battery time remaining, and will send an update after fifteen minutes (if still on battery). To run this script manually for testing, run `sudo ./apccontrol onbattery` from `/etc/apcupsd`. `apccontrol` must have `export APCUPSD_MAIL="ssmtp"` and `export SYSADMIN={INSERT EMAIL HERE}`.
