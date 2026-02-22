#!/bin/bash

# --- OLLAMA ULTIMATE DASHBOARD v16.0 ---
# Features: LAN Fix, Persistent DB, Version Check, CPU/GPU Monitor
# Author: Gemini & User

# Slå av job-control meldinger
set +m

# Fil for lagring av resultater
DB_FILE="ollama_benchmark_db.txt"

# Cache vars
declare -A speed_cache

# Sjekk dependencies
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Missing dependency: $cmd. Installing..."
        sudo apt update && sudo apt install -y $cmd
    fi
done

# --- DATABASE FUNCTIONS ---
load_benchmarks() {
    if [ -f "$DB_FILE" ]; then
        while IFS="=" read -r model speed; do
            speed_cache["$model"]="$speed"
        done < "$DB_FILE"
    fi
}

save_benchmark() {
    local model=$1
    local speed=$2
    speed_cache["$model"]="$speed"
    if [ -f "$DB_FILE" ]; then
        grep -v "^$model=" "$DB_FILE" > "${DB_FILE}.tmp"
        mv "${DB_FILE}.tmp" "$DB_FILE"
    fi
    echo "$model=$speed" >> "$DB_FILE"
}

# --- VERSION CHECK ---
check_versions() {
    CURRENT_VER=$(ollama -v 2>&1 | grep "version is" | awk '{print $4}')
    if [ -z "$CURRENT_VER" ]; then CURRENT_VER="Unknown"; fi
    LATEST_VER=$(curl -s --max-time 2 https://api.github.com/repos/ollama/ollama/releases/latest | jq -r .tag_name)
    
    if [[ "$LATEST_VER" == "v$CURRENT_VER" ]] || [[ "$LATEST_VER" == "$CURRENT_VER" ]]; then
        VER_STATUS="\033[1;32mUP TO DATE\033[0m"
    else
        VER_STATUS="\033[1;33mUPDATE AVAIL: $LATEST_VER\033[0m"
    fi
}

# --- CLEANUP ON EXIT ---
cleanup() {
    kill $MONITOR_PID 2>/dev/null
    tput csr 0 $(tput lines)
    tput cnorm
    echo ""
    exit
}
trap cleanup INT TERM EXIT

# --- SYSTEM MONITORING ---
get_cpu_usage() {
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    cpu_active_prev=$((user+nice+system+irq+softirq+steal))
    cpu_total_prev=$((user+nice+system+idle+iowait+irq+softirq+steal))
    sleep 0.5
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    cpu_active_cur=$((user+nice+system+irq+softirq+steal))
    cpu_total_cur=$((user+nice+system+idle+iowait+irq+softirq+steal))
    cpu_total_diff=$((cpu_total_cur - cpu_total_prev))
    cpu_active_diff=$((cpu_active_cur - cpu_active_prev))
    if [ $cpu_total_diff -eq 0 ]; then echo "0"; else echo $(( (cpu_active_diff * 100) / cpu_total_diff )); fi
}

update_dashboard_stats() {
    # GPU
    if command -v nvidia-smi &> /dev/null; then
        stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits)
        IFS=',' read -r gpu_load vram_used vram_total gpu_temp <<< "$stats"
        
        gpu_load=$(echo $gpu_load | tr -d ' ')
        vram_used=$(echo $vram_used | tr -d ' ')
        vram_total=$(echo $vram_total | tr -d ' ')
        gpu_temp=$(echo $gpu_temp | tr -d ' ')

        if [ "$vram_total" -gt 0 ]; then vram_pct=$(( (vram_used * 100) / vram_total )); else vram_pct=0; fi
        vram_used_gb=$(awk "BEGIN {printf \"%.1f\", $vram_used/1024}")
        vram_total_gb=$(awk "BEGIN {printf \"%.0f\", $vram_total/1024}")
        
        if [ $vram_pct -ge 90 ]; then c_vram="\033[1;31m"; elif [ $vram_pct -ge 50 ]; then c_vram="\033[1;33m"; else c_vram="\033[1;32m"; fi
    else
        gpu_load="N/A"; gpu_temp="-"; vram_used_gb="0"; vram_total_gb="0"; vram_pct="0"; c_vram="\033[0m"
    fi

    # CPU
    cpu_pct=$(get_cpu_usage)
    if [ $cpu_pct -ge 80 ]; then c_cpu="\033[1;31m"; elif [ $cpu_pct -ge 50 ]; then c_cpu="\033[1;33m"; else c_cpu="\033[1;32m"; fi
    
    reset="\033[0m"; bold="\033[1m"

    # --- DRAW HEADER ---
    tput sc
    tput cup 2 0
    echo -e "   OLLAMA: ${bold}v${CURRENT_VER}${reset}  |  STATUS: ${VER_STATUS}           "
    tput cup 3 0
    echo -e "   CPU: ${c_cpu}${cpu_pct}%${reset}   |   GPU: ${gpu_load}%   |   Temp: ${gpu_temp}°C      "
    tput cup 4 0
    echo -e "   VRAM: ${c_vram}${vram_used_gb} GB / ${vram_total_gb} GB (${vram_pct}%)${reset}           "
    tput rc
}

monitor_loop() {
    while true; do update_dashboard_stats; done
}

setup_scroll_region() {
    clear
    tput csr 7 $(tput lines)
    tput cup 0 0
    echo "========================================================================="
    echo "   OLLAMA ULTIMATE DASHBOARD v16.0"
    echo "========================================================================="
    # Linje 2-4 fylles av monitor
    tput cup 5 0
    echo "========================================================================="
    tput cup 6 0
    echo "   LOG OUTPUT:"
    echo "-------------------------------------------------------------------------"
}

# --- CORE FUNCTIONS ---
get_server_config() {
    FILE="/etc/systemd/system/ollama.service.d/override.conf"
    CTX="4096 (Default)"
    HOST="127.0.0.1 (Local)"
    
    if [ -f "$FILE" ]; then
        # Hent Context
        val_ctx=$(grep "OLLAMA_NUM_CTX" "$FILE" | awk -F'=' '{print $NF}' | tr -d '"')
        if [[ "$val_ctx" =~ ^[0-9]+$ ]]; then CTX="$val_ctx"; fi
        
        # Hent Host
        val_host=$(grep "OLLAMA_HOST" "$FILE" | awk -F'=' '{print $NF}' | tr -d '"')
        if [[ "$val_host" == "0.0.0.0" ]]; then HOST="0.0.0.0 (LAN)"; fi
    fi
    echo "$CTX|$HOST"
}

# --- FIX: THIS FUNCTION NOW SAVES BOTH SETTINGS ---
configure_server() {
    echo "-------------------------------------------------------"
    echo " SERVER CONFIGURATION (Requires sudo)"
    echo "-------------------------------------------------------"
    
    # 1. Ask for Context
    read -p " Enter Global Context Size (Default 4096, e.g. 32768): " new_ctx
    if [ -z "$new_ctx" ]; then new_ctx="4096"; fi

    # 2. Ask for LAN
    read -p " Enable LAN Access (Allows other PCs to connect)? (y/n): " lan_choice
    
    echo " Writing configuration..."
    
    # Create dir
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    
    # Write [Service] block
    echo "[Service]" | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
    
    # Write Context
    echo "Environment=\"OLLAMA_NUM_CTX=$new_ctx\"" | sudo tee -a /etc/systemd/system/ollama.service.d/override.conf > /dev/null
    
    # Write Host (LAN Logic)
    if [[ "$lan_choice" == "y" ]]; then
        echo "Environment=\"OLLAMA_HOST=0.0.0.0\"" | sudo tee -a /etc/systemd/system/ollama.service.d/override.conf > /dev/null
        echo " LAN Access: ENABLED (0.0.0.0)"
    else
        # If 'n', we don't write OLLAMA_HOST, so it defaults to localhost
        echo " LAN Access: DISABLED (Localhost only)"
    fi
    
    echo " Reloading systemd and restarting Ollama..."
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
    sleep 3
    speed_cache=() # Clear cache
}

unload_model() {
    local m_name=$1
    curl -s -X POST http://localhost:11434/api/generate -d '{ "model": "'"$m_name"'", "keep_alive": 0 }' > /dev/null
}

run_benchmark() {
    local model_name=$1
    echo " > Testing: $model_name"
    
    unload_model "$model_name"
    
    echo -ne "   Pre-heating... "
    curl -s -X POST http://localhost:11434/api/generate -d '{ "model": "'"$model_name"'", "prompt": "" }' > /dev/null
    echo "Ready."

    echo "   Running Benchmark..."
    prompt="Write a short poem about Linux in exactly 50 words."
    
    json_response=$(curl -s -X POST http://localhost:11434/api/generate -d '{
        "model": "'"$model_name"'",
        "prompt": "'"$prompt"'",
        "stream": false
    }')
    
    eval_count=$(echo "$json_response" | grep -Po '"eval_count":\K[0-9]+')
    eval_duration=$(echo "$json_response" | grep -Po '"eval_duration":\K[0-9]+')
    
    if [ -z "$eval_count" ]; then
        eval_count=$(echo "$json_response" | grep -o '"eval_count":[0-9]*' | awk -F: '{print $2}')
        eval_duration=$(echo "$json_response" | grep -o '"eval_duration":[0-9]*' | awk -F: '{print $2}')
    fi

    unload_model "$model_name"

    if [ -n "$eval_count" ] && [ -n "$eval_duration" ] && [ "$eval_duration" -gt 0 ]; then
        speed=$(awk "BEGIN {printf \"%.2f\", $eval_count / ($eval_duration / 1000000000)}")
        save_benchmark "$model_name" "$speed"
        echo -e "   Result: \033[1;32m$speed t/s\033[0m"
    else
        save_benchmark "$model_name" "Error"
        echo -e "   Result: \033[1;31mError\033[0m"
    fi
    echo "-------------------------------------------------------------------------"
}

# --- INIT ---
echo "Loading Dashboard..."
load_benchmarks
check_versions
setup_scroll_region
monitor_loop &
MONITOR_PID=$!

# --- MAIN LOOP ---
while true; do
    # Hent config (CTX og HOST)
    CONFIG_STR=$(get_server_config)
    IFS='|' read -r S_CTX S_HOST <<< "$CONFIG_STR"
    
    # Fargelegg HOST status
    if [[ "$S_HOST" == *"LAN"* ]]; then
        HOST_DISPLAY="\033[1;32m$S_HOST\033[0m"
    else
        HOST_DISPLAY="\033[1;31m$S_HOST\033[0m"
    fi

    echo ""
    echo -e "   [ CTX: $S_CTX ]  [ HOST: $HOST_DISPLAY ]"
    echo ""
    
    raw_data=($(ollama list | awk 'NR>1 {print $1 "|" $3 $4}'))
    if [ ${#raw_data[@]} -eq 0 ]; then
        echo "   (No models found)"
    else
        printf "   %-4s %-38s %-10s %s\n" "NR" "MODEL NAME" "SIZE" "SPEED"
        echo "   ---------------------------------------------------------------------"
        for i in "${!raw_data[@]}"; do
            IFS="|" read -r m_name m_size <<< "${raw_data[$i]}"
            cached_speed=${speed_cache["$m_name"]}
            if [ -z "$cached_speed" ]; then disp_speed="-"; else disp_speed="$cached_speed t/s"; fi
            
            if [ "$cached_speed" == "Error" ]; then
                printf "   %2d)  %-38s %-10s \033[0;31m%s\033[0m\n" "$((i+1))" "$m_name" "[$m_size]" "ERROR"
            else
                printf "   %2d)  %-38s %-10s \033[0;32m%s\033[0m\n" "$((i+1))" "$m_name" "[$m_size]" "$disp_speed"
            fi
        done
    fi

    echo ""
    echo " [0] INSTALL / UPDATE OLLAMA"
    echo " [1] Benchmark Single"
    echo " [2] Benchmark ALL (Update DB)"
    echo " [3] Refresh Menu"
    echo " [4] Pull New Model"
    echo " [5] Create Custom Context Model"
    echo " [6] CONFIGURE SERVER (LAN & Context) -> Fixes LAN issues"
    echo " [7] Delete Model"
    echo " [9] Exit"
    echo ""
    read -p " Select Action: " action

    get_model_name() {
        local idx=$(( $1 - 1 ))
        local entry=${raw_data[$idx]}
        echo "${entry%%|*}"
    }

    case $action in
        0)
            kill $MONITOR_PID 2>/dev/null
            tput cnorm
            curl -fsSL https://ollama.com/install.sh | sh
            echo "Done. Checking version..."
            check_versions
            monitor_loop &
            MONITOR_PID=$!
            ;;
        1)
            echo ""
            read -p " Select Model NR: " n
            target=$(get_model_name "$n")
            [ -n "$target" ] && run_benchmark "$target"
            ;;
        2)
            echo ""
            echo " Starting Sequence..."
            for i in "${!raw_data[@]}"; do
                IFS="|" read -r m_name m_ignore <<< "${raw_data[$i]}"
                run_benchmark "$m_name"
                sleep 1
            done
            ;;
        3) ;;
        4)
            read -p " Model name: " new_model
            [ -n "$new_model" ] && ollama pull "$new_model"
            ;;
        5)
            read -p " Select model NR to copy: " n
            target=$(get_model_name "$n")
            if [ -n "$target" ]; then
                read -p " Context size (e.g. 32000): " ctx
                suffix=$(echo $ctx | tr -d ' ')
                new_name="${target}-${suffix}"
                echo "FROM $target" > Modelfile.temp
                echo "PARAMETER num_ctx $ctx" >> Modelfile.temp
                ollama create "$new_name" -f Modelfile.temp
                rm Modelfile.temp
            fi
            ;;
        6)
            configure_server
            ;;
        7)
            read -p " Select model NR to delete: " n
            target=$(get_model_name "$n")
            [ -n "$target" ] && ollama rm "$target" && save_benchmark "$target" ""
            ;;
        9) cleanup ;;
        *) ;;
    esac
done
