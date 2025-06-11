#!/bin/bash

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
HASHRATE_LOG=$(mktemp)

# Variables
DURATION=3600
XMRIG_PATH="$REAL_HOME/.local/bin/xmrig"
XMRIG_API_URL="http://127.0.0.1:8080/1/summary"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Functions
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

echo "========================================"
echo "AMD Zen 4 Multi-Core Performance Tester"
echo "========================================"
echo "Duration: ${DURATION}s all-core test"
echo ""

# Get baseline temperatures
temp_start_ccd0=$(sensors | grep "Tccd1:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
temp_start_ccd1=$(sensors | grep "Tccd2:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")

echo "Thermal baselines:"
echo "  CCD0 baseline: ${temp_start_ccd0}°C"
echo "  CCD1 baseline: ${temp_start_ccd1}°C"
echo ""

echo "Starting XMRig for all-core test..."

# Start XMRig using config file
nohup $XMRIG_PATH \
    --http-enabled \
    --http-host=127.0.0.1 \
    --http-port=8080 \
    --algo=rx/0 \
    --stress \
    --huge-pages \
    --randomx-1gb-pages \
    --cpu-priority 3 \
    --threads 32 \
    < /dev/null > /dev/null 2>&1 &

xmrig_pid=$!
echo "XMRig PID: $xmrig_pid (using 32 threads)"

echo "Waiting for XMRig to initialize..."

# Simple monitoring loop
echo "Running test for ${DURATION}s..."
test_start_time=$(date +%s)

while [ $(($(date +%s) - test_start_time)) -lt $DURATION ]; do
    # Get current metrics
    current_hashrate=$(get_current_hashrate "$XMRIG_API_URL")

    current_temp_ccd0=$(sensors | grep "Tccd1:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
    current_temp_ccd1=$(sensors | grep "Tccd2:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
    
    elapsed=$(($(date +%s) - test_start_time))
    remaining=$((DURATION - elapsed))
    
    if [[ -n "$current_hashrate" ]]; then
        echo "⚡ ${elapsed}s: ${current_hashrate} H/s | CCD0: ${current_temp_ccd0}°C | CCD1: ${current_temp_ccd1}°C | ${remaining}s remaining"
        echo "$current_hashrate" >> "$HASHRATE_LOG"
    else
        echo "⏳ ${elapsed}s: API unavailable | CCD0: ${current_temp_ccd0}°C | CCD1: ${current_temp_ccd1}°C | ${remaining}s remaining"
    fi
    
    sleep 10
done

# Get final temperatures
temp_end_ccd0=$(sensors | grep "Tccd1:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
temp_end_ccd1=$(sensors | grep "Tccd2:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")


# Get final total hashes
echo "Getting final hashrate data..."
api_response=$(curl -s --connect-timeout 5 "$XMRIG_API_URL")
final_total_hashes=$(echo "$api_response" | jq -r '.results.hashes_total // 0')

# Stop XMRig
echo "Stopping XMRig..."
kill -9 $xmrig_pid 2>/dev/null
pkill -9 xmrig 2>/dev/null

echo ""
echo "=============================================="
echo "Multi-core test complete!"
echo "=============================================="
echo "CCD0: ${temp_start_ccd0}°C → ${temp_end_ccd0}°C"
echo "CCD1: ${temp_start_ccd1}°C → ${temp_end_ccd1}°C"

# Calculate average hashrate
if [ -s "$HASHRATE_LOG" ]; then
    total=0
    count=0
    while IFS= read -r rate; do
        total=$(echo "$total + $rate" | bc)
        count=$((count + 1))
    done < "$HASHRATE_LOG"
    
    avg_hashrate=$(echo "scale=2; $total / $count" | bc)
    echo "Average Hashrate: ${avg_hashrate} H/s (based on $count readings)"
else
    echo "Average Hashrate: N/A (no valid readings)"
fi

# Clean up
rm -f "$HASHRATE_LOG"
