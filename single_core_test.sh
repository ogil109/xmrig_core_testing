#!/bin/bash

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
HASHRATE_LOG=$(mktemp)

# Variables
DURATION=3600
OUTPUT="single_core_results.csv"
XMRIG_PATH="$REAL_HOME/.local/bin/xmrig"
XMRIG_API_URL="http://127.0.0.1:8080/1/summary"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

echo "========================================"
echo "AMD Zen 4 Single-Core Performance Tester"
echo "========================================"
echo "Duration: ${DURATION}s per simlet pair"
echo "Total test time: ~$(( DURATION * TOTAL_CORES / 60 )) minutes + thermal recovery"
echo ""

# Auto-detect CPU core count
detect_cpu_cores() {
    local physical_cores=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
    local sockets=$(lscpu | grep "Socket(s):" | awk '{print $2}')
    echo $(( physical_cores * sockets ))
}

TOTAL_CORES=$(detect_cpu_cores)
echo "Detected $TOTAL_CORES physical cores"

# Create CSV header
echo "Physical_Core,CCD,Hashrate_H/s,Avg_Freq_MHz,Max_Freq_MHz,Boost_Ratio,Tccd_Start,Tccd_Peak,Temp_Delta,Stable,Notes" > $OUTPUT

# CPU frequency monitoring
get_cpu_freq() {
    local cpu=$1
    if [ -r "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq" ]; then
        freq_khz=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq 2>/dev/null)
        echo $(( freq_khz / 1000 ))
    else
        echo "0"
    fi
}

# CCD temperature monitoring
get_ccd_temp() {
    local ccd=$1
    local sensor_name=""
    
    # Auto-detect available CCD temperature sensors
    if [ $ccd -eq 0 ]; then
        sensor_name=$(sensors | grep -E "Tccd1:|Tdie:" | head -1 | cut -d: -f1)
    else
        sensor_name=$(sensors | grep -E "Tccd2:|Tdie:" | tail -1 | cut -d: -f1)
    fi
    
    if [ -n "$sensor_name" ]; then
        sensors | grep "$sensor_name:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Calculate CPU affinity mask for simlet pair
calculate_affinity_mask() {
    local core1=$1
    local core2=$2
    local decimal_mask=$(echo "2^$core1 + 2^$core2" | bc)
    printf "0x%X" $decimal_mask
}

