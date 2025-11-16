![Screenshot of tool](https://media.discordapp.net/attachments/1087338689883017217/1439633784575365120/image.png?ex=691b3af1&is=6919e971&hm=bce1413fe38b942ad485c90c789a13aec16412a4ca3fe92743d5b85496ad3219&=&format=webp&quality=lossless)

## What it does:
This is a tool I made for OpenRC which replicates the functionality of the "systemd-analyze" command, for the most part.

## How it does it:
Firmware and Loader times are pulled directly from the ACPI Firmware Performance Data Table, so should be accurate.
The rest of the times are pulled from DMESG which has a tendancy to be inaccurate over long periods, but for the small duration all the bootup tasks happen, it should be relatively accurate.

## Future plans:
Right now, DMESG doesn't provide a good way to detect when userspace is reached, so i'm using the elogind service as an indicator for when that happens. This isn't nessesarily that inaccurate, but it's not the best either.
I'd like to find a way to replace this functionality. I'm looking into using RC Log instead with verbose logging to see if I can pull times from that.

## Requirements:
The only 2 requirements is that your running OpenRC and using elogind. Once I have time to change how userspace is detected, elogind won't be required.

## Installation:
```
git clone https://github.com/adaster98/openrc-analyze/
cd openrc-analyze
sudo cp openrc-analyze.sh /bin/openrc-analyze
```
Then use `sudo openrc-analyze`

## Bugs:
~~If user hibernates their system, it will pull the firmware and loader stats from the *last* boot, not the original boot.~~
Part-fixed: Script will now detect a resumed session and indentify times as such.
