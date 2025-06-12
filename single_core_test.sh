#!/bin/bash

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

# Variables
DURATION=$1
MONITOR_INTERVAL=${2:-5}

OUTPUT="single_core_results.csv"
XMRIG_PATH="$REAL_HOME/.local/bin/xmrig"
XMRIG_API_URL="http://127.0.0.1:8080/1/summary"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Auto-detect CPU core count
detect_cpu_cores() {
    local physical_cores=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
    local sockets=$(lscpu | grep "Socket(s):" | awk '{print $2}')
    echo $(( physical_cores * sockets ))
}

TOTAL_CORES=$(detect_cpu_cores)
echo "Detected $TOTAL_CORES physical cores"

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

get_current_hashrate() {
    local api_url=$1
    local api_response
    local http_code
    local json_content
    local hashrate
    local max_retries=30
    local retry_delay=1

    # Keep trying until we get a valid hashrate
    for i in $(seq 1 $max_retries); do
        api_response=$(curl -s -w "%{http_code}" --connect-timeout 5 "$api_url" 2>/dev/null)
        http_code=${api_response: -3}
        json_content=${api_response%???}
        
        if [ "$http_code" -eq 200 ]; then
            hashrate=$(echo "$json_content" | jq -r '.hashrate.total[0] // empty' 2>/dev/null)
            if [[ -n "$hashrate" ]] && (( $(echo "$hashrate > 0" | bc -l) )); then
                echo "$hashrate"
                return 0
            fi
        fi
        
        # Wait before retrying
        sleep $retry_delay
    done
    
    echo ""
    return 1
}

# Adaptive thermal baseline management
wait_for_thermal_baseline() {
    local ccd=$1
    local target_temp=$2
    local tolerance=2
    local min_stable_time=10
    local max_wait=120
    
    echo "  Waiting for thermal baseline (target: ${target_temp}°C ±${tolerance}°C)..."
    
    local stable_count=0
    local required_stable_samples=$((min_stable_time / 2))
    
    for i in $(seq 1 $max_wait); do
        current_temp=$(get_ccd_temp $ccd)
        
        if (( $(awk "BEGIN {print ($current_temp <= $target_temp + $tolerance) ? 1 : 0}") )); then
            stable_count=$((stable_count + 1))
            echo -n "  ✅ At baseline: ${current_temp}°C (stable ${stable_count}/${required_stable_samples})  "
            
            if [ $stable_count -ge $required_stable_samples ]; then
                echo ""
                echo "  🎯 Thermal baseline achieved and stable (${i}s total)"
                return 0
            fi
        else
            stable_count=0
            echo -n "  Cooling: ${current_temp}°C → ${target_temp}°C (${i}/${max_wait}s)  "
        fi
        
        sleep 2
        echo -ne "\r"
    done
    
    echo ""
    current_temp=$(get_ccd_temp $ccd)
    echo "  ⚠️  Thermal baseline timeout: ${current_temp}°C (continuing anyway)"
    return 1
}

echo "========================================"
echo "AMD Zen 4 Single-Core Performance Tester"
echo "========================================"
echo "Duration: ${DURATION}s per simlet pair"
echo "Total test time: ~$(( DURATION * TOTAL_CORES / 60 )) minutes + thermal recovery"
echo ""

# Create CSV header
echo "Timestamp,Physical_Core,CCD,Hashrate_H/s,Freq,CCD_Temp" > $OUTPUT

# Establish thermal baselines
echo "Establishing thermal baselines..."
echo "Please ensure system is idle for accurate baseline measurement."
echo "Waiting 30 seconds for thermal stabilization..."
sleep 30

# Auto-detect number of CCDs
CCD_COUNT=$(( (TOTAL_CORES + 7) / 8 ))  # 8 cores per CCD
echo "Detected $CCD_COUNT CCD(s)"

# Get baseline temperatures for each CCD
declare -a IDLE_TEMPS
for ccd in $(seq 0 $((CCD_COUNT - 1))); do
    IDLE_TEMPS[$ccd]=$(get_ccd_temp $ccd)
    echo "  CCD$ccd idle baseline: ${IDLE_TEMPS[$ccd]}°C"
done

echo ""
echo "Starting simlet pair testing..."
echo ""

# Test each simlet pair with correct SMT thread calculation and cooldown logic
for core in $(seq 0 $((TOTAL_CORES - 1))); do
    smt_thread=$((core + TOTAL_CORES))
    ccd=$((core / 8))
    
    affinity_mask=$(calculate_affinity_mask $core $smt_thread)
    idle_baseline=${IDLE_TEMPS[$ccd]}
    
    echo "=== Testing Physical Core $core (CCD$ccd, logical CPUs $core,$smt_thread) ==="
    echo "  CPU Affinity Mask: $affinity_mask"
    echo "  Target thermal baseline: ${idle_baseline}°C"
    
    # Only wait for thermal baseline if testing the same CCD as previous core
    if [ $core -gt 0 ]; then
        prev_core=$((core - 1))
        prev_ccd=$((prev_core / 8))
        
        if [ $ccd -eq $prev_ccd ]; then
            echo "  Same CCD as previous test - waiting for thermal recovery"
            wait_for_thermal_baseline $ccd $idle_baseline
        else
            echo "  Different CCD from previous test - no thermal recovery needed"
            echo "  Previous: Core $prev_core (CCD$prev_ccd), Current: Core $core (CCD$ccd)"
        fi
    fi
    
    # Get actual test start temperature
    temp_start=$(get_ccd_temp $ccd)
    echo "  Test start CCD$ccd: ${temp_start}°C"
    
    # Start XMRig
    echo "  Starting XMRig..."
    nohup $XMRIG_PATH \
        --http-enabled \
        --http-host=127.0.0.1 \
        --http-port=8080 \
        --algo=rx/0 \
        --stress \
        --huge-pages \
        --randomx-1gb-pages \
        --cpu-priority 3 \
        --threads 2 \
        --cpu-affinity $affinity_mask \
    < /dev/null > /dev/null 2>&1 &
    
    xmrig_pid=$!
    echo "  XMRig PID: $xmrig_pid"

    # Wait for API to initialize
    echo "Waiting for XMRig to initialize..."
    sleep 10

    # Monitoring loop
    echo "  Starting monitoring..."
    test_start_time=$(date +%s)
    
    while [ $(($(date +%s) - test_start_time)) -lt $DURATION ]; do
        # Get current metrics
        current_hashrate=$(get_current_hashrate "$XMRIG_API_URL")
        current_freq=$(get_cpu_freq $core)
        current_temp=$(get_ccd_temp $ccd)
        timestamp=$(date +%s)
        
        # Log to CSV
        echo "$timestamp,$core,$ccd,${current_hashrate:-0},$current_freq,$current_temp" >> "$OUTPUT"

        elapsed=$(($(date +%s) - test_start_time))
        remaining=$((DURATION - elapsed))
        
        # Print status
        if [[ -n "$current_hashrate" ]]; then
            echo "⚡ ${elapsed}s: ${current_hashrate} H/s | Core ${core} @ ${current_freq} MHz | CCD${ccd}: ${current_temp}°C | ${remaining}s remaining"
        else
            echo "⏳ ${elapsed}s: API unavailable | Core ${core} @ ${current_freq} MHz | CCD${ccd}: ${current_temp}°C | ${remaining}s remaining"
        fi
        
        sleep $MONITOR_INTERVAL
    done
    
    # Stop XMRig
    echo "  Stopping XMRig..."
    kill -9 $xmrig_pid 2>/dev/null
    pkill -9 xmrig 2>/dev/null

done

echo ""
echo "=============================================="
echo "Single-core test complete!"
echo "=============================================="
echo "Detailed performance data saved to: $OUTPUT"