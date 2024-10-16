#!/bin/bash
set -e

# Define colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[1;37m"
RESET="\033[0m"

show_logs() {
    echo "Viewing Story and Story-Geth logs (press 'q' to return to the menu)..."
    sudo journalctl -u story-geth -u story -f &   # Start logs in the background
    log_pid=$!                                   # Save the PID of the journalctl process

    # Function to handle cleanup
    cleanup() {
        pkill -P $log_pid                         # Kill the journalctl process group
        stty echo                                 # Enable echo back
        stty icanon                               # Restore canonical mode
        echo -e "\nLog viewer closed."            # Inform the user
    }

    # Set up trap to catch exit signal
    trap cleanup SIGINT SIGTERM

    # Disable keyboard echo and canonical mode
    stty -echo
    stty -icanon

    while true; do
        read -n 1 key                             # Read a single character
        if [[ $key == "q" ]]; then
            cleanup                               # Call cleanup function
            break                                 # Exit the loop to return to the menu
        fi
    done

    cleanup                                       # Ensure cleanup is called when breaking the loop
}


check_story_geth_status() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}  Check story-geth Status ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    sudo systemctl status story-geth
    echo
    read -n 1 -s -r -p "Press any key to return to the menu..." key
}

check_story_status() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}    Check story Status     ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    sudo systemctl status story
    echo
    read -n 1 -s -r -p "Press any key to return to the menu..." key
}

check_disk_space() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}   Check Disk Space       ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    
    df_output=$(df -h / | tail -1)
    total_space=$(echo $df_output | awk '{print $2}')
    used_space=$(echo $df_output | awk '{print $3}')
    available_space=$(echo $df_output | awk '{print $4}')
    use_percentage=$(echo $df_output | awk '{print $5}')

    echo -e "${BLUE}Partition: /${RESET}"
    echo -e "${YELLOW}----------------------------------------${RESET}"
    printf "| %-20s | %-10s |\n" "Total Disk" "$total_space"
    printf "| %-20s | %-10s |\n" "Used Space" "$used_space"
    printf "| %-20s | %-10s |\n" "Available Space" "$available_space"
    printf "| %-20s | %-10s |\n" "Usage" "$use_percentage"
    echo -e "${YELLOW}----------------------------------------${RESET}"

    read -n 1 -s -r -p "Press any key to return to the menu..." key
}

install_dependencies() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}    Install Dependencies   ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    sudo apt-get update
    if ! sudo apt-get install -y python3-pip jq; then
        echo -e "${RED}Error installing dependencies.${RESET}"
        return
    fi
    if ! pip3 install bech32; then
        echo -e "${RED}Error installing bech32.${RESET}"
        return
    fi
    echo -e "${GREEN}Dependencies installed successfully.${RESET}"
}

check_python_dependencies() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}   Check Python Libraries   ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    if ! python3 -c "import bech32" &>/dev/null; then
        echo -e "${YELLOW}Library 'bech32' is not installed. Installing...${RESET}"
        install_dependencies
    else
        echo -e "${GREEN}All necessary libraries are installed.${RESET}"
    fi
}

run_python_script() {
    echo -e "${CYAN}==========================${RESET}"
    echo -e "${GREEN}  Run HEX to Bech32 Conversion  ${RESET}"
    echo -e "${CYAN}==========================${RESET}"
    
    check_python_dependencies

    cat << 'EOF' > /tmp/hex_to_bech32.py
import subprocess
import bech32

def hex_to_bytes(hex_str):
    return bytes.fromhex(hex_str)

def convert_to_bech32(hex_str, prefix):
    byte_data = hex_to_bytes(hex_str)
    bech32_address = bech32.bech32_encode(prefix, bech32.convertbits(byte_data, 8, 5))
    return bech32_address

def get_hex_address():
    result = subprocess.run(
        ["curl", "-s", "http://localhost:26657/status"],
        capture_output=True,
        text=True,
        check=True
    )
    hex_address = subprocess.run(
        ["jq", "-r", ".result.validator_info.address"],
        input=result.stdout,
        capture_output=True,
        text=True,
        check=True
    )
    return hex_address.stdout.strip()

def main():
    try:
        prefix = "storyvaloper"
        hex_address = get_hex_address()
        bech32_address = convert_to_bech32(hex_address, prefix)
        print(f"Bech32 Address: {bech32_address}")
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    main()
EOF

    python3 /tmp/hex_to_bech32.py
    read -n 1 -s -r -p "Press any key to return to the menu..." key
}

create_telegram_alert_service() {
    read -p "Enter your Telegram bot token: " tg_bot_token
    read -p "Enter channel ID: " channel_id

    alert_script="/usr/local/bin/telegram_alert.sh"
    echo -e "${CYAN}Creating Telegram alert script...${RESET}"
    cat << EOF | sudo tee "$alert_script"
#!/bin/bash
tg_bot_token="\$1"
channel_id="\$2"

while true; do
    df_output=\$(df / | tail -1)
    used_space=\$(echo \$df_output | awk '{print \$3}')
    use_percentage=\$(echo \$df_output | awk '{print \$5}' | tr -d '%')

    if [ "\$use_percentage" -gt 95 ]; then
        message="Warning! Disk usage exceeds 95%: \$used_space used."
        curl -s -X POST "https://api.telegram.org/bot\$tg_bot_token/sendMessage" -d "chat_id=\$channel_id&text=\$message"
    fi

    for service in story story-geth; do
        if ! systemctl is-active --quiet \$service; then
            message="Service \$service is not active."
            curl -s -X POST "https://api.telegram.org/bot\$tg_bot_token/sendMessage" -d "chat_id=\$channel_id&text=\$message"
        fi
    done

    sleep 600
done
EOF

    sudo chmod +x "$alert_script"

    service_file="/etc/systemd/system/telegram_alert.service"
    echo -e "${CYAN}Creating Telegram alert service...${RESET}"
    cat << EOF | sudo tee "$service_file"
[Unit]
Description=Telegram Alert Service

[Service]
Type=simple
ExecStart=$alert_script $tg_bot_token $channel_id
EOF

    timer_file="/etc/systemd/system/telegram_alert.timer"
    echo -e "${CYAN}Creating timer for service...${RESET}"
    cat << EOF | sudo tee "$timer_file"
[Unit]
Description=Run Telegram Alert Service every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable telegram_alert.timer
    sudo systemctl start telegram_alert.timer

    echo -e "${GREEN}Telegram alerts successfully set up!${RESET}"
    read -n 1 -s -r -p "Press any key to return to the menu..." key
}

update_peers() {
    echo -e "${CYAN}\n--- Updating Peers ---${RESET}\n"
  
    PEERS=$(curl -sS https://snapshotstory.shablya.io/net_info | 
    jq -r '.result.peers[] | select(.node_info.id != null and .remote_ip != null and .node_info.listen_addr != null) | 
    "\(.node_info.id)@\(if .node_info.listen_addr | contains("0.0.0.0") then .remote_ip + ":" + (.node_info.listen_addr | sub("tcp://0.0.0.0:"; "")) else (.node_info.listen_addr | sub("tcp://"; "")) end)"' | 
    paste -sd ',')

    PEERS="\"$PEERS\""

    if [ -n "$PEERS" ]; then
        sed -i "s/^persistent_peers *=.*/persistent_peers = $PEERS/" "$HOME/.story/story/config/config.toml"
        if [ $? -eq 0 ]; then
            echo -e "Configuration file updated successfully with new peers"
        else
            echo "Failed to update configuration file."
        fi
    else
        echo "No peers found to update."
    fi
}

update_addrbook() {
    echo -e "${CYAN}\n--- Updating addrbook.json ---${RESET}\n"
    wget -q -O /root/.story/story/config/addrbook.json https://snapshotstory.shablya.io/addrbook.json
    sudo systemctl restart story-geth && sudo systemctl restart story 
    echo -e "${GREEN}\naddrbook.json successfully updated!${RESET}"
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================${RESET}"
        echo -e "${MAGENTA}   SHABLYA STORY UTILITY   ${RESET}"
        echo -e "${CYAN}==========================${RESET}"
        echo -e "${YELLOW}1) View Logs${RESET}"
        echo -e "${YELLOW}2) Check story-geth Status${RESET}"
        echo -e "${YELLOW}3) Check story Status${RESET}"
        echo -e "${YELLOW}4) Check Disk Space${RESET}"
        echo -e "${YELLOW}5) Update Snapshots${RESET}"
        echo -e "${YELLOW}6) Check your validator address${RESET}"
        echo -e "${YELLOW}7) Create Telegram Alert Service${RESET}"
        echo -e "${YELLOW}8) Update Peers${RESET}"
        echo -e "${YELLOW}9) Update addrbook${RESET}"
        echo -e "${YELLOW}q) Quit${RESET}"
        echo -e "${CYAN}==========================${RESET}"
        
        read -p "Choose an option: " choice
        case "$choice" in
            1) show_logs ;;
            2) check_story_geth_status ;;
            3) check_story_status ;;
            4) check_disk_space ;;
            5) update_snapshots ;;
            6) run_python_script ;;
            7) create_telegram_alert_service ;;
            8) update_peers ;;
            9) update_addrbook ;;
            q) echo "Exiting..."; break ;;
            *) echo -e "${RED}Invalid choice. Please try again.${RESET}"; sleep 2 ;;
        esac
    done
}

main_menu
