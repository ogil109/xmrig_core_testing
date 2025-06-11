#!/bin/bash

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

# Variables
DURATION=300
OUTPUT="multicore_results.csv"
XMRIG_PATH="$REAL_HOME/.local/bin/xmrig"
XMRIG_API_URL="http://127.0.0.1:8080/1/summary"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

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

# Wait for API to become available
echo "Waiting for XMRig API to initialize..."
api_wait_time=30
api_ready=false

for i in $(seq 1 $api_wait_time); do
    if curl -s --connect-timeout 1 "$XMRIG_API_URL" >/dev/null 2>&1; then
        api_ready=true
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

if ! $api_ready; then
    echo "  ⚠️  XMRig API not responding after $api_wait_time seconds"
    echo "  Check XMRig logs or try: curl $XMRIG_API_URL"
else
    echo "  ✅ XMRig API responding"
fi

# Simple monitoring loop
echo "Running test for ${DURATION}s..."
test_start_time=$(date +%s)

while [ $(($(date +%s) - test_start_time)) -lt $DURATION ]; do
    # Get current metrics
    # Get hashrate with detailed error reporting
    current_hashrate="0"
    for i in {1..3}; do
        api_response=$(curl -s -w "%{http_code}" --connect-timeout 5 "$XMRIG_API_URL" 2>/dev/null)
        http_code=${api_response: -3}
        json_content=${api_response%???}
        
        if [ "$http_code" -eq 200 ]; then
            current_hashrate=$(echo "$json_content" | jq -r '.hashrate.total[0] // empty' 2>/dev/null)
            if [ -n "$current_hashrate" ]; then
                break
            fi
        else
            echo "  ⚠️  API Error: HTTP $http_code (attempt $i/3)"
        fi
        sleep 2
    done

    current_temp_ccd0=$(sensors | grep "Tccd1:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
    current_temp_ccd1=$(sensors | grep "Tccd2:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
    
    elapsed=$(($(date +%s) - test_start_time))
    remaining=$((DURATION - elapsed))
    
    if [[ "$current_hashrate" != "0" && "$current_hashrate" != "" ]]; then
        echo "⚡ ${elapsed}s: ${current_hashrate} H/s | CCD0: ${current_temp_ccd0}°C | CCD1: ${current_temp_ccd1}°C | ${remaining}s remaining"
    else
        echo "⏳ ${elapsed}s: Waiting for hashrate | CCD0: ${current_temp_ccd0}°C | CCD1: ${current_temp_ccd1}°C | ${remaining}s remaining"
    fi
    
    sleep 10
done

# Get final temperatures
temp_end_ccd0=$(sensors | grep "Tccd1:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")
temp_end_ccd1=$(sensors | grep "Tccd2:" | awk '{print $2}' | tr -d '+°C' 2>/dev/null || echo "0")

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
