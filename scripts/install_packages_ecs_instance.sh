#!/bin/bash
# Command to get the IP of the current server
LOCAL_IP=$(hostname -I | awk '{print $1}')
# INSTALL ZSH
sudo chmod +x $HOME/statarb/scripts/install_terminal_linux.sh
$HOME/statarb/scripts/install_terminal_linux.sh






