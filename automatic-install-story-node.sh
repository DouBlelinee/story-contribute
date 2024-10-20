#!/bin/bash


install_if_missing() {
  if ! command -v "$1" &> /dev/null; then
    echo "$1 not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y "$1"
  else
    echo "$1 is already installed."
  fi
}


install_if_missing curl
install_if_missing jq


GREEN="\033[0;32m"
BOLD="\033[1m"
NC="\033[0m" 
printBlue() {
  echo -e "\033[1;34m$1\033[0m"
}

printGreen() {
  echo -e "\033[1;32m$1\033[0m"
}
printRed() {
  echo -e "\033[1;31m$1\033[0m"
}

printLine() {
  echo -e "--------------------------------------------------"
}


from_autoinstall=true


upgrade_height=0
STORY_CHAIN_ID=iliad-0
VER=1.22.3
SEEDS="51ff395354c13fab493a03268249a74860b5f9cc@story-testnet-seed.itrocket.net:26656"


PEERS="$(curl -s https://server-3.itrocket.net/testnet/story/.rpc_combined.json | jq -r 'to_entries | map(select(.key | test("^https://") | not)) | map("\(.value.id)@\(.key)") | join(",")')"


for cmd in curl jq systemctl; do
  command -v $cmd > /dev/null 2>&1 || { echo "Error: $cmd is not installed." >&2; exit 1; }
done


ask_to_continue() {
  read -p "$(printYellow 'Do you want to continue anyway? (y/n): ')" choice
  if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
    break
  fi
}

install_geth() {
  cd $HOME
  wget -O geth https://github.com/piplabs/story-geth/releases/download/v0.9.4/geth-linux-amd64
  chmod +x $HOME/geth
  mv $HOME/geth ~/go/bin/
  [ ! -d "$HOME/.story/story" ] && mkdir -p "$HOME/.story/story"
  [ ! -d "$HOME/.story/geth" ] && mkdir -p "$HOME/.story/geth"
}


install_story() {
  cd $HOME
  rm -rf story
  git clone https://github.com/piplabs/story
  cd story
  git checkout v0.11.0
  go build -o story ./client 
  mv $HOME/story/story $HOME/go/bin/
}


install_node() {
    read -p "Enter your Validator Name: " MONIKER
    export MONIKER
    echo "export MONIKER=\"$MONIKER\"" >> $HOME/.bash_profile

    STORY_CHAIN_ID="iliad-0"
    export STORY_CHAIN_ID
    echo "export STORY_CHAIN_ID=\"$STORY_CHAIN_ID\"" >> $HOME/.bash_profile

    printGreen "Validator Name: $MONIKER"
    printGreen "Chain ID: $STORY_CHAIN_ID"

    source $HOME/.bash_profile

    printGreen "1. Checking Go version..." && sleep 1
    CURRENT_VER=$(go version 2>/dev/null | awk '{print $3}' | cut -c3-)

    if [ "$CURRENT_VER" == "$VER" ]; then
      printGreen "Go version $VER is already installed. Skipping installation."
    else
      printGreen "Installing Go version $VER..."
      cd $HOME
      wget "https://golang.org/dl/go$VER.linux-amd64.tar.gz"
      sudo rm -rf /usr/local/go
      sudo tar -C /usr/local -xzf "go$VER.linux-amd64.tar.gz"
      rm "go$VER.linux-amd64.tar.gz"
      [ ! -f ~/.bash_profile ] && touch ~/.bash_profile
      echo "export PATH=$PATH:/usr/local/go/bin:~/go/bin" >> ~/.bash_profile
      source $HOME/.bash_profile
      [ ! -d ~/go/bin ] && mkdir -p ~/go/bin
    fi

    echo $(go version) && sleep 1

    printGreen "2. Updating packages..." && sleep 1
    sudo apt update && sudo apt upgrade -y

    printGreen "3. Installing dependencies..." && sleep 1
    sudo apt install curl git wget htop tmux jq make lz4 unzip bc -y

    printGreen "4. Installing Story-geth..." && sleep 1
    install_geth

    printGreen "5. Installing Story..." && sleep 1
    install_story

    printGreen "6. Initializing Story app..." && sleep 1
    story init --moniker $MONIKER --network iliad
    sleep 1

    printGreen "7. Downloading genesis and addrbook..." && sleep 1
    wget -O $HOME/.story/story/config/genesis.json https://server-3.itrocket.net/testnet/story/genesis.json
    wget -O $HOME/.story/story/config/addrbook.json https://server-3.itrocket.net/testnet/story/addrbook.json
    sleep 1

    printGreen "8. Adding seeds and peers..." && sleep 1
    sed -i -e "/^\[p2p\]/,/^\[/{s/^[[:space:]]*seeds *=.*/seeds = \"$(printf '%s' "$SEEDS" | sed 's/[\/&]/\\&/g')\"/}" \
       -e "/^\[p2p\]/,/^\[/{s/^[[:space:]]*persistent_peers *=.*/persistent_peers = \"$(printf '%s' "$PEERS" | sed 's/[\/&]/\\&/g')\"/}" \
       $HOME/.story/story/config/config.toml

    sleep 1
    printBlue "done"
    printLine
  printGreen "9. Creating Story-geth and Story service files..." && sleep 1

sudo tee /etc/systemd/system/story-geth.service > /dev/null <<EOF
[Unit]
Description=Story Geth daemon
After=network-online.target

[Service]
User=$USER
ExecStart=$HOME/go/bin/geth --iliad --syncmode full 
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF


sudo tee /etc/systemd/system/story.service > /dev/null <<EOF
[Unit]
Description=Story Service
After=network.target

[Service]
User=$USER
WorkingDirectory=$HOME/.story/story
ExecStart=$(which story) run

Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  
sleep 1
printBlue "done"

printLine
printGreen "10. Activating Story and Story-geth services..." && sleep 1
sudo systemctl daemon-reload
sudo systemctl enable story story-geth

sleep 1
printBlue "done"

printLine


read -p "$(printGreen 'Do you want to download the snapshot? (y/n): ')" download_choice
if [[ "$download_choice" == "y" || "$download_choice" == "Y" ]]; then
  printGreen "11. Downloading snapshot..." && sleep 1
  echo ""
  printLine
  installation=true
  mkdir -p $HOME/.story/geth/iliad/geth
  source <(curl -s https://itrocket.net/api/testnet/story/autosnap/)
else
  printGreen "Skipping snapshot download. Starting services..." 
  sudo systemctl start story-geth
  sudo systemctl start story
fi
}


check_sync_status() {
  rpc_port=$(grep -m 1 -oP '^laddr = "\K[^"]+' "$HOME/.story/story/config/config.toml" | cut -d ':' -f 3)
  
  trap "echo -e '\nExiting sync status...'; return" SIGINT  

  while true; do
    local_height=$(curl -s localhost:$rpc_port/status | jq -r '.result.sync_info.latest_block_height')
    network_height=$(curl -s https://story-testnet-rpc.itrocket.net/status | jq -r '.result.sync_info.latest_block_height')

    if ! [[ "$local_height" =~ ^[0-9]+$ ]] || ! [[ "$network_height" =~ ^[0-9]+$ ]]; then
      echo -e "\033[1;31mError: Invalid block height data. Retrying...\033[0m"
      sleep 5
      continue
    fi

    blocks_left=$(echo "$network_height - $local_height" | bc)
    if [ "$blocks_left" -lt 0 ]; then
      blocks_left=0
    fi

    echo -e "\033[1;33mYour Node Height:\033[1;34m $local_height\033[0m \033[1;33m| Network Height:\033[1;36m $network_height\033[0m \033[1;33m| Blocks Left:\033[1;31m $blocks_left\033[0m"

    sleep 5
    if [[ "$blocks_left" -eq 0 ]]; then
      printBlue "Your node is synced"
      break
    fi
  done

  trap - SIGINT 
}



define_service_name() {
  service_name=$1
  print_name=$2
  systemctl status $service_name > /dev/null 2>&1
  exit_code=$?
  if [[ $exit_code -eq 4 ]]; then
    read -rp "Enter your $print_name service file name: " service_name
  fi
  echo $service_name
}

view_logs() {
  if [[ -z "$story_name" ]]; then
    story_name=$(define_service_name "story" "Story")
  fi
  if [[ -z "$geth_name" ]]; then
    geth_name=$(define_service_name "story-geth" "Story-geth")
  fi

  trap "echo -e '\nExiting logs view...'; return" SIGINT 

  journalctl -u $story_name -u $geth_name -f

  trap - SIGINT 
}


restore_validator_key() {
     if [[ $EUID -eq 0 ]]; then
        user_home=$(eval echo ~$SUDO_USER)
        user_name=$SUDO_USER
    else
        user_home=$HOME
        user_name=$USER
    fi

    backup_file="$user_home/Downloads/priv_validator_key.json.backup"
    restore_path="$HOME/.story/story/config/priv_validator_key.json"

    if [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$restore_path"
        printGreen "Restore successful: $backup_file -> $restore_path"

        chown "$user_name:$user_name" "$restore_path"
        chmod 700 "$restore_path"


        printRed "Stopping services..."
        sudo systemctl stop story
        sudo systemctl stop story-geth


        printGreen "Starting services..."
        sudo systemctl start story-geth
        sudo systemctl start story
    else
        printRed "Backup file not found: $backup_file"
    fi

}

main() {
    action=0
    while [[ $action -ne 9 ]]; do
        echo -e "${GREEN}${BOLD}Welcome to the Story Node Installation! By 0xdoubleline${NC}"
        options=(
            "Auto Install Story node"
            "Manually upgrade Story & Story-geth to the latest version"
            "Export Validator Key for Move To New Hardware Stored in Downloads"
            "Restore Validator Key from Downloads"
            "Download snapshot"
            "Check Block sync status"
            "Check logs"
            "Delete Story & Story-geth"
            "Exit"
        )
        for i in "${!options[@]}"; do
            printf "%s. %s\n" "$((i + 1))" "${options[$i]}"
        done
        read -rp "Your choice: " action
        echo ""

        if [[ $action -eq 1 ]]; then
          printLine
          install_node
          printGreen "Autoinstallation complete!"
          printLine

        elif [[ $action -eq 2 ]]; then
          printLine
          printGreen "1. Installing Story-geth..." && sleep 1
          install_geth

          printLine
          printGreen "2. Installing Story..." && sleep 1
          install_story

          printLine
          printGreen "3. Restarting Story and Story-geth..." && sleep 1
          if [[ -z "$story_name" ]]; then
            story_name=$(define_service_name "story" "Story")
          fi
          if [[ -z "$geth_name" ]]; then
            geth_name=$(define_service_name "story-geth" "Story-geth")
          fi

          if sudo systemctl restart $story_name $geth_name; then
            printBlue "Story and Story-geth restarted"
            echo ""
            printGreen "Story and Story-geth upgraded to the latest version."
          else
            printRed "Failed to restart services"
            ask_to_continue
          fi

        elif [[ $action -eq 3 ]]; then

          if [[ $EUID -eq 0 ]]; then
              user_home=$(eval echo ~$SUDO_USER)  
              user_name=$SUDO_USER 
          else
              user_home=$HOME  
              user_name=$USER  
          fi


          src="$HOME/.story/story/config/priv_validator_key.json"
          dest="$user_home/Downloads/priv_validator_key.json.backup"

          if [[ -f "$src" ]]; then
              cp "$src" "$dest"
              chown "$user_name:$user_name" "$dest"  
              chmod 755 "$dest"  
              printGreen "Backup successful: $src -> $dest"
          else
              printRed "File not found: $src"
          fi

        elif [[ $action -eq 4 ]]; then
          restore_validator_key

        elif [[ $action -eq 5 ]]; then
          installation=false
          source <(curl -s https://itrocket.net/api/testnet/story/autosnap/)

        elif [[ $action -eq 6 ]]; then
          printLine
          printGreen "Displaying node sync status Use CTRL+C to stop logs and get back to the menu."
          check_sync_status

        elif [[ $action -eq 7 ]]; then
          printLine
          view_logs

        elif [[ $action -eq 8 ]]; then
          printLine
          read -p "$(printRed 'Are you sure that you want to delete your node? (y/n): ')" delete_confirmation
          if [[ "$delete_confirmation" == "y" || "$delete_confirmation" == "Y" ]]; then
            printGreen "1. Backing up priv_validator_state.json..."
            if cp "$HOME/.story/story/data/priv_validator_state.json" "$HOME/priv_validator_state.json.backup"; then
              printBlue "done"
            else
              printRed "Failed to backup priv_validator_state.json"
              ask_to_continue
            fi

            printGreen "2. Deleting Story and Story-geth..."
            if [[ -z "$story_name" ]]; then
              story_name=$(define_service_name "story" "Story")  
            fi
            if [[ -z "$geth_name" ]]; then
              geth_name=$(define_service_name "story-geth" "Story-geth")  
            fi
            if sudo systemctl stop $story_name $geth_name; then
              printBlue "Story and Story-geth stopped"
            else
              printRed "Failed to stop services"
              ask_to_continue
            fi
            rm -rf $HOME/.story
            if sudo rm /etc/systemd/system/$story_name.service /etc/systemd/system/$geth_name.service; then
              printBlue "Story and Story-geth service files removed"
              echo ""
              printGreen "Story and Story-geth deleted"
            else
              printRed "Failed to remove service files"
            fi
            sudo systemctl daemon-reload
          fi
        elif [[ $action -eq 9 ]]; then
          printRed "Exiting the script..."
          printLine
        elif [[ $action -lt 1 || $action -gt 9 ]]; then
          printRed "Invalid choice. Please select a number between 1 and 9."
        fi 
    done  
    from_autoinstall=false
}

main
