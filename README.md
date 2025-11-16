What it does:
This is a tool I made for OpenRC which replicates the functionality of the "systemd-analyze" command, for the most part.

How it does it:
Firmware and Loader times are pulled directly from the ACPI Firmware Performance Data Table, so should be accurate.
The rest of the times are pulled from DMESG which has a tendancy to be inaccurate over long periods, but for the small duration all the bootup tasks happen, it should be relatively accurate.

Future plans:
Right now, DMESG doesn't provide a good way to detect when userspace is reached, so i'm using the elogind service as an indicator for when that happens. This isn't nessesarily that inaccurate, but it's not the best either.
I'd like to find a way to replace this functionality. I'm looking into using RC Log instead with verbose logging to see if I can pull times from that.
