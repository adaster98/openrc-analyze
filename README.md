![Screenshot of tool](https://media.discordapp.net/attachments/1440257131495428116/1440274694614810634/image.png?ex=691d8fd6&is=691c3e56&hm=158b8adedd393d4c453bbb04a96c7cf1420ab10cab6af200e413b464d2efeb30&=&format=webp&quality=lossless)

## What it does:
This is a tool I made for OpenRC which replicates the functionality of the "systemd-analyze" command, for the most part.


## How it does it:
Firmware and Loader times are pulled directly from the ACPI Firmware Performance Data Table, so should be accurate.
Kernel and initramfs times are pulled from DMESG which has a tendancy to be inaccurate over long periods, but for the small duration all the bootup tasks happen, it should be relatively accurate.
Userspace is detected either when the elogind service starts, or if you have rc_logger enabled, when the default runlevel has finished.

## Requirements:
- OpenRC system
- Kernel must have CONFIG_ACPI_FPDT enabled
- Using elogind OR have rc_logger enabled

## Installation:
Note: I build this script for the Gentoo distro, I can't say if will work on others.
```
git clone https://github.com/adaster98/openrc-analyze/
cd openrc-analyze
sudo cp openrc-analyze.sh /bin/openrc-analyze
```
Then use `sudo openrc-analyze`

## Bugs:
[1] ~~If user hibernates their system, it will pull the firmware and loader stats from the *last* boot, not the original boot~~.

EDIT: Script will now detect a resumed session and label the new times as (on-resume).

[2] After system has been running for a while, or after many alterations, the dmesg file gets filled and overflows to a new page causing the script to break.

[3] One Gentoo user found that init system path was /sbin/init vs /user/bin/init causing the dmsg grep to fail. A possible cause for this is chosing a non-desktop profile.
