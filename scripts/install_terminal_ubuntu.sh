#!/bin/bash

# Upgrade the system Ubuntu
sudo apt-get update && sudo apt-get upgrade -y

# Install git
sudo apt-get install git -y

# Navigate to the home directory
cd $HOME

# Check if the terminal-profile folder exists and update or clone the repo
if [ -d "$HOME/terminal-profile" ]; then
    cd $HOME/terminal-profile
    git pull origin main
else
    git clone https://github.com/gptcompany/terminal-profile.git
fi

# Make executable the files in terminal-profile folder
chmod +x $HOME/terminal-profile/install_powerline_ubuntu.sh
chmod +x $HOME/terminal-profile/install_terminal_ubuntu.sh
chmod +x $HOME/terminal-profile/install_profile_ubuntu.sh

# Run the scripts
cd $HOME/terminal-profile
$HOME/terminal-profile/install_powerline_ubuntu.sh
$HOME/terminal-profile/install_terminal_ubuntu.sh
$HOME/terminal-profile/install_profile_ubuntu.sh
cd
