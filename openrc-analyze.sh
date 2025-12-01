#!/bin/bash

# OpenRC Analyze - By Aster (InvertedBug)

# --------------
# Initial checks
# --------------
detect_resume() {
    # Check if system was resumed from hibernation
    if dmesg | grep -q "PM: hibernation: hibernation exit"; then
        echo "resume"
    else
        echo "cold"
    fi
}

is_rc_logger_enabled() {
    # Check if debug argument was passed
    if [ "${FORCE_ELOGIND:-0}" -eq 1 ]; then
        echo "disabled"
        return
    fi

    # Check if rc_logger is enabled in /etc/rc.conf
    if [ -f "/etc/rc.conf" ]; then
        if grep -q '^rc_logger="YES"' /etc/rc.conf || grep -q '^rc_logger="yes"' /etc/rc.conf; then
            echo "enabled"
        else
            echo "disabled"
        fi
    else
        echo "disabled"
    fi
}

# --------------
# Time Detection
# --------------

get_firmware_time() {
    # Firmware time: from power-on to bootloader launch
    local bootloader_launch_ns=0

    if [ -f "/sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" ]; then
        bootloader_launch_ns=$(cat "/sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" 2>/dev/null || echo "0")
    else
        echo "ERROR: Cannot find /sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" >&2
        return 1
    fi

    if [ "$bootloader_launch_ns" -gt 0 ]; then
        # Convert nanoseconds to seconds
        local duration_s=$(echo "scale=3; $bootloader_launch_ns / 1000000000" | bc -l 2>/dev/null)
        echo $duration_s
    else
        echo "ERROR: Invalid value in bootloader_launch_ns: $bootloader_launch_ns" >&2
        return 1
    fi
}

get_bootloader_time() {
    # Bootloader time: from bootloader launch to exit boot services
    local bootloader_launch_ns=0
    local exitbootservice_end_ns=0

    if [ -f "/sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" ]; then
        bootloader_launch_ns=$(cat "/sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" 2>/dev/null || echo "0")
    else
        echo "ERROR: Cannot find /sys/firmware/acpi/fpdt/boot/bootloader_launch_ns" >&2
        return 1
    fi

    if [ -f "/sys/firmware/acpi/fpdt/boot/exitbootservice_end_ns" ]; then
        exitbootservice_end_ns=$(cat "/sys/firmware/acpi/fpdt/boot/exitbootservice_end_ns" 2>/dev/null || echo "0")
    else
        echo "ERROR: Cannot find /sys/firmware/acpi/fpdt/boot/exitbootservice_end_ns" >&2
        return 1
    fi

    if [ "$bootloader_launch_ns" -gt 0 ] && [ "$exitbootservice_end_ns" -gt 0 ]; then
        # Convert nanoseconds to seconds
        local duration_s=$(echo "scale=3; ($exitbootservice_end_ns - $bootloader_launch_ns) / 1000000000" | bc -l 2>/dev/null)
        echo $duration_s
    else
        echo "ERROR: Invalid values - bootloader_launch_ns: $bootloader_launch_ns, exitbootservice_end_ns: $exitbootservice_end_ns" >&2
        return 1
    fi
}

get_kernel_time() {
    # Kernel starts at dmesg timestamp 0.000
    # Kernel ends when early userspace/initramfs starts OR when userspace starts if no initramfs

    # First, check for initramfs start (this is the primary kernel end marker)
    local early_userspace_start=$(dmesg | grep -i "Run /init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    # If no initramfs start found, then kernel ends when userspace starts directly
    if [ -z "$early_userspace_start" ]; then
        early_userspace_start=$(dmesg | grep -i "Running init: /sbin/init\|Running init: /usr/bin/init\|dracut: Switching root\|Run /sbin/init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)
    fi

    if [ -n "$early_userspace_start" ]; then
        echo $early_userspace_start
    else
        echo "ERROR: Cannot find kernel end marker in dmesg" >&2
        return 1
    fi
}

get_initramfs_time() {
    # Initramfs/early userspace starts at "Run /init as init process"
    # Initramfs ends at "Running init: /*" or "dracut: Switching root" (handoff to main system)

    local initramfs_start=$(dmesg | grep -i "Run /init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    # If no initramfs start marker found, assume no initramfs
    if [ -z "$initramfs_start" ]; then
        echo "0"
        return 0
    fi

    # Look for possible init paths
    local initramfs_end=$(dmesg | grep -i "Running init: /sbin/init\|Running init: /usr/bin/init\|dracut: Switching root\|Run /sbin/init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -n "$initramfs_start" ] && [ -n "$initramfs_end" ]; then
        local duration_s=$(echo "scale=3; $initramfs_end - $initramfs_start" | bc -l 2>/dev/null)
        echo $duration_s
    else
        echo "ERROR: Cannot find initramfs boundaries in dmesg" >&2
        echo "ERROR: initramfs_start: '$initramfs_start', initramfs_end: '$initramfs_end'" >&2
        return 1
    fi
}

get_openrc_times() {
    local rc_log="/var/log/rc.log"

    if [ ! -f "$rc_log" ]; then
        echo "ERROR: Cannot find OpenRC log file: $rc_log" >&2
        return 1
    fi

    # 1 -- Use AWK to scan forward and capture the last *complete* boot sequence.
    # I used a pipe delimiter (|) to output all lines in one go, which is safer than array splitting.
    local raw_output
    raw_output=$(awk '
        /rc boot logging started/    { bs=$0; b_stop=""; d_start=""; d_stop="" }
        /rc boot logging stopped/    { b_stop=$0 }
        /rc default logging started/ { d_start=$0 }
        /rc default logging stopped/ {
            d_stop=$0
            # Only update our "final" variables if we have a full, valid sequence.
            # This automatically ignores incomplete boot cycles at the end of the file.
            if (bs && b_stop && d_start && d_stop) {
                final_bs=bs
                final_b_stop=b_stop
                final_d_start=d_start
                final_d_stop=d_stop
            }
        }
        END {
            if (final_bs) {
                print final_bs "|" final_b_stop "|" final_d_start "|" final_d_stop
            }
        }
    ' "$rc_log")

    if [ -z "$raw_output" ]; then
        echo "ERROR: No complete boot cycle found." >&2
        return 1
    fi

    # 2 -- Read the pipe-delimited string into variables
    local IFS='|'
    read -r line_bs line_be line_ds line_de <<< "$raw_output"
    unset IFS

    # 3 -- Extract date strings (columns 6-10 correspond to the timestamp format in your log)
    local date_bs=$(echo "$line_bs" | awk '{print $6, $7, $8, $9, $10}')
    local date_be=$(echo "$line_be" | awk '{print $6, $7, $8, $9, $10}')
    local date_ds=$(echo "$line_ds" | awk '{print $6, $7, $8, $9, $10}')
    local date_de=$(echo "$line_de" | awk '{print $6, $7, $8, $9, $10}')

    # 4 -- Convert to epoch seconds
    local epoch_bs=$(date -d "$date_bs" +%s 2>/dev/null)
    local epoch_be=$(date -d "$date_be" +%s 2>/dev/null)
    local epoch_ds=$(date -d "$date_ds" +%s 2>/dev/null)
    local epoch_de=$(date -d "$date_de" +%s 2>/dev/null)

    # 5 -- Validate dates
    if [ -z "$epoch_bs" ] || [ -z "$epoch_be" ] || [ -z "$epoch_ds" ] || [ -z "$epoch_de" ]; then
        echo "ERROR: Failed to parse OpenRC timestamps." >&2
        return 1
    fi

    # 6 -- Calculate durations
    local boot_duration=$((epoch_be - epoch_bs))
    local default_duration=$((epoch_de - epoch_ds))
    local total_userspace=$((epoch_de - epoch_bs))

    # 7 -- Output variables
    echo "$total_userspace,$boot_duration,$default_duration"
}

get_userspace_time_fallback() {
    # Fallback method: Use elogind service start as userspace completion marker

    local userspace_start=$(dmesg | grep -i "Running init: /sbin/init\|Running init: /usr/bin/init\|dracut: Switching root\|Run /sbin/init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -z "$userspace_start" ]; then
        echo "ERROR: Cannot find userspace start marker in dmesg" >&2
        return 1
    fi

    # Use elogind starting as the marker for userspace completion
    local userspace_end=$(dmesg | grep -i "elogind-daemon" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -n "$userspace_end" ] && [ "$userspace_end" != "0.000000" ]; then
        local duration_s=$(echo "scale=3; $userspace_end - $userspace_start" | bc -l 2>/dev/null)
        echo "$duration_s"
    else
        echo "ERROR: Cannot find 'elogind-daemon' in dmesg" >&2
        return 1
    fi
}

get_userspace_time() {
    # Try OpenRC log method first, fall back to elogind method if not available
    local rc_logger_status=$(is_rc_logger_enabled)

    if [ "$rc_logger_status" = "enabled" ]; then
        local openrc_times
        if openrc_times=$(get_openrc_times 2>/dev/null); then
            # Extract total userspace time (first field)
            local total_userspace=$(echo "$openrc_times" | cut -d',' -f1)
            echo "$total_userspace"
            return 0
        fi
    fi

    # Fall back to elogind method
    get_userspace_time_fallback
}

# -----------------------
# Checks before execution
# -----------------------

# Parse commandline arguments
FORCE_ELOGIND=0
if [ "$1" = "use-elogind" ]; then
    FORCE_ELOGIND=1
fi

echo ""

# Detect if this is a cold boot or resume
boot_type=$(detect_resume)

# Check rc_logger status
rc_logger_status=$(is_rc_logger_enabled)

# Set labels based on boot type
if [ "$boot_type" = "resume" ]; then
    firmware_label="firmware on-resume"
    bootloader_label="loader on-resume"
else
    firmware_label="firmware"
    bootloader_label="loader"
fi

# Collect all times with error handling
errors=0

if ! firmware_time=$(get_firmware_time); then
    errors=1
    firmware_time="ERROR"
fi

if ! bootloader_time=$(get_bootloader_time); then
    errors=1
    bootloader_time="ERROR"
fi

if ! kernel_time=$(get_kernel_time); then
    errors=1
    kernel_time="ERROR"
fi

if ! initramfs_time=$(get_initramfs_time); then
    errors=1
    initramfs_time="ERROR"
fi

if ! userspace_time=$(get_userspace_time); then
    errors=1
    userspace_time="ERROR"
fi

# Get detailed OpenRC times if available
if [ "$rc_logger_status" = "enabled" ]; then
    if openrc_times=$(get_openrc_times 2>/dev/null); then
        boot_duration=$(echo "$openrc_times" | cut -d',' -f2)
        default_duration=$(echo "$openrc_times" | cut -d',' -f3)
        openrc_available=1
    else
        openrc_available=0
    fi
else
    openrc_available=0
fi

# Check if initramfs is actually used
if [ "$initramfs_time" = "0" ]; then
    initramfs_used=0
else
    initramfs_used=1
fi

# --------------
# Main Execution
# --------------

# Calculate total time only if all components are available
if [ $errors -eq 0 ]; then
    # Adjust total time calculation based on initramfs usage
    if [ $initramfs_used -eq 1 ]; then

        total_time=$(echo "scale=3; $firmware_time + $bootloader_time + $kernel_time + $initramfs_time + $userspace_time" | bc -l 2>/dev/null)
    else

        total_time=$(echo "scale=3; $firmware_time + $bootloader_time + $kernel_time + $userspace_time" | bc -l 2>/dev/null)
    fi

    # Format output
    printf "Complete Breakdown:\n"
    printf "\u2022 %s: %.3fs\n" "$firmware_label" "$firmware_time"
    printf "\u2022 %s: %.3fs\n" "$bootloader_label" "$bootloader_time"
    printf "\u2022 kernel: %.3fs\n" "$kernel_time"

    if [ $initramfs_used -eq 1 ]; then
        printf "\u2022 initramfs: %.3fs\n" "$initramfs_time"
    else
        printf "\u2022 initramfs: not used\n"
    fi

    if [ $openrc_available -eq 1 ]; then
        printf "\u2022 userspace: %.0fs (boot) + %.0fs (default)\n" "$boot_duration" "$default_duration"
    else
        printf "\u2022 userspace: %.3fs\n" "$userspace_time"
    fi

    echo ""
    printf "Total Time: %.3fs\n" "$total_time"

    # Show resume notice if applicable
    if [ "$boot_type" = "resume" ]; then
        echo ""
        echo "Note: System was resumed from hibernation."
        echo "Firmware and loader times reflect resume initialization."
    fi

    # Show rc_logger notice if disabled
    if [ "$rc_logger_status" = "disabled" ]; then
        echo ""
        echo "Note: rc_logger is disabled. Userspace time is estimated from elogind start."
        echo "Enable rc_logger in /etc/rc.conf for verbose runlevel timing."
    fi

    # Show initramfs notice if not used
    if [ $initramfs_used -eq 0 ]; then
        echo ""
        echo "Note: No initramfs detected. Kernel time includes direct transition to userspace."
    fi
else
    echo "ERROR: Could not calculate boot times. Missing data:"
    [ "$firmware_time" = "ERROR" ] && echo "  - Firmware time"
    [ "$bootloader_time" = "ERROR" ] && echo "  - Bootloader time"
    [ "$kernel_time" = "ERROR" ] && echo "  - Kernel time"
    [ "$initramfs_time" = "ERROR" ] && echo "  - Initramfs time"
    [ "$userspace_time" = "ERROR" ] && echo "  - Userspace time"
    echo ""
    echo "Please ensure:"
    echo "  - Script is run as root"
    echo "  - ACPI FPDT is available in /sys/firmware/acpi/fpdt/"
    echo "  - System uses OpenRC with standard init messages"
    echo "  - System is using elogind or has rc_logger enabled"
    exit 1
fi
