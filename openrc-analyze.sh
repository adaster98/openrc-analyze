#!/bin/bash

# OpenRC systemd-analyze equivalent script
# Using dmesg timestamps, ACPI FPDT data, and OpenRC rc.log

detect_resume() {
    # Check if system was resumed from hibernation
    if dmesg | grep -q "PM: hibernation: hibernation exit"; then
        echo "resume"
    else
        echo "cold"
    fi
}

is_rc_logger_enabled() {
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
    # Kernel ends when early userspace/initramfs starts
    local early_userspace_start=$(dmesg | grep -i "Run /init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -n "$early_userspace_start" ]; then
        echo $early_userspace_start
    else
        echo "ERROR: Cannot find 'Run /init as init process' in dmesg" >&2
        return 1
    fi
}

get_initramfs_time() {
    # Initramfs/early userspace starts at "Run /init as init process"
    # Initramfs ends at "Running init: /usr/bin/init" (handoff to main system)
    local initramfs_start=$(dmesg | grep -i "Run /init as init process" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)
    local initramfs_end=$(dmesg | grep -i "Running init: /usr/bin/init" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

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
    # Get OpenRC runlevel times from rc.log
    local rc_log="/var/log/rc.log"

    if [ ! -f "$rc_log" ]; then
        echo "ERROR: Cannot find OpenRC log file: $rc_log" >&2
        return 1
    fi

    # Get the last boot cycle (most recent set of log entries)
    local boot_start_line=$(grep "rc boot logging started" "$rc_log" | tail -1)
    local boot_stop_line=$(grep "rc boot logging stopped" "$rc_log" | tail -1)
    local default_start_line=$(grep "rc default logging started" "$rc_log" | tail -1)
    local default_stop_line=$(grep "rc default logging stopped" "$rc_log" | tail -1)

    if [ -z "$boot_start_line" ] || [ -z "$boot_stop_line" ] || [ -z "$default_start_line" ] || [ -z "$default_stop_line" ]; then
        echo "ERROR: Cannot find complete OpenRC runlevel data in $rc_log" >&2
        return 1
    fi

    # Extract timestamps
    local boot_start_time=$(echo "$boot_start_line" | awk '{print $6, $7, $8, $9, $10}')
    local boot_stop_time=$(echo "$boot_stop_line" | awk '{print $6, $7, $8, $9, $10}')
    local default_start_time=$(echo "$default_start_line" | awk '{print $6, $7, $8, $9, $10}')
    local default_stop_time=$(echo "$default_stop_line" | awk '{print $6, $7, $8, $9, $10}')

    # Convert to epoch seconds for calculation
    local boot_start_epoch=$(date -d "$boot_start_time" +%s 2>/dev/null)
    local boot_stop_epoch=$(date -d "$boot_stop_time" +%s 2>/dev/null)
    local default_start_epoch=$(date -d "$default_start_time" +%s 2>/dev/null)
    local default_stop_epoch=$(date -d "$default_stop_time" +%s 2>/dev/null)

    if [ -z "$boot_start_epoch" ] || [ -z "$boot_stop_epoch" ] || [ -z "$default_start_epoch" ] || [ -z "$default_stop_epoch" ]; then
        echo "ERROR: Cannot parse timestamps from OpenRC log" >&2
        return 1
    fi

    # Calculate durations
    local boot_duration=$((boot_stop_epoch - boot_start_epoch))
    local default_duration=$((default_stop_epoch - default_start_epoch))
    local total_userspace=$((default_stop_epoch - boot_start_epoch))

    # Return as comma-separated values: total_userspace,boot_duration,default_duration
    echo "$total_userspace,$boot_duration,$default_duration"
}

get_userspace_time_fallback() {
    # Fallback method: Use elogind service start as userspace completion marker
    local userspace_start=$(dmesg | grep -i "Running init: /usr/bin/init" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -z "$userspace_start" ]; then
        echo "ERROR: Cannot find 'Running init: /usr/bin/init' in dmesg" >&2
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

# Main execution
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

# Calculate total time only if all components are available
if [ $errors -eq 0 ]; then
    total_time=$(echo "scale=3; $firmware_time + $bootloader_time + $kernel_time + $initramfs_time + $userspace_time" | bc -l 2>/dev/null)

    # Format output
    printf "Complete Breakdown:\n"
    printf "\u2022 %s: %.3fs\n" "$firmware_label" "$firmware_time"
    printf "\u2022 %s: %.3fs\n" "$bootloader_label" "$bootloader_time"
    printf "\u2022 kernel: %.3fs\n" "$kernel_time"
    printf "\u2022 initramfs: %.3fs\n" "$initramfs_time"

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
