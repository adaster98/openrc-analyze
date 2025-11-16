#!/bin/bash

# OpenRC systemd-analyze equivalent script
# Using dmesg timestamps and ACPI FPDT data

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

get_userspace_time() {
    # Userspace starts when initramfs ends and main system init begins
    local userspace_start=$(dmesg | grep -i "Running init: /usr/bin/init" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -z "$userspace_start" ]; then
        echo "ERROR: Cannot find 'Running init: /usr/bin/init' in dmesg" >&2
        return 1
    fi

    # Use elogind starting as the marker for userspace completion
    local userspace_end=$(dmesg | grep -i "elogind-daemon" | head -1 | awk '{print $2}' | tr -d '[]' 2>/dev/null)

    if [ -n "$userspace_end" ] && [ "$userspace_end" != "0.000000" ]; then
        local duration_s=$(echo "scale=3; $userspace_end - $userspace_start" | bc -l 2>/dev/null)
        echo $duration_s
    else
        echo "ERROR: Cannot find 'elogind-daemon' in dmesg" >&2
        return 1
    fi
}

# Main execution
echo "OpenRC Analyze :3"
echo "==============================="

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

# Calculate total time only if all components are available
if [ $errors -eq 0 ]; then
    total_time=$(echo "scale=3; $firmware_time + $bootloader_time + $kernel_time + $initramfs_time + $userspace_time" | bc -l 2>/dev/null)
    # Format output like systemd-analyze
    printf "Startup finished in %.3fs (firmware) + %.3fs (loader) + %.3fs (kernel) + %.3fs (initramfs) + %.3fs (userspace) = %.2fs\n" \
           "$firmware_time" \
           "$bootloader_time" \
           "$kernel_time" \
           "$initramfs_time" \
           "$userspace_time" \
           "$total_time"
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
    exit 1
fi
