#!/bin/bash

# Upgrade the system (Amazon Linux)
sudo yum update -y

# Install git
sudo yum install git -y

# Navigate to the home directory
cd $HOME

# Check if the terminal-profile folder exists and update or clone the repo
if [ -d "$HOME/terminal-profile" ]; then
    cd $HOME/terminal-profile
    git pull origin main --force
else
    git clone https://github.com/gptcompany/terminal-profile.git
fi

# Make executable the files in terminal-profile folder
chmod +x $HOME/terminal-profile/install_powerline_linux.sh
chmod +x $HOME/terminal-profile/install_terminal_linux.sh
chmod +x $HOME/terminal-profile/install_profile_linux.sh

# Run the scripts

# Check if Oh My Zsh is installed
if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "Oh My Zsh is already installed."
else
    echo "Installing Oh My Zsh..."
    cd $HOME/terminal-profile
    $HOME/terminal-profile/install_powerline_linux.sh
    $HOME/terminal-profile/install_terminal_linux.sh
fi

# Check if Powerlevel10k is installed
if [ -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
    echo "Powerlevel10k theme is already installed."
else
    echo "Installing Powerlevel10k theme..."
    cd $HOME/terminal-profile
    $HOME/terminal-profile/install_profile_linux.sh
fi

# Set Zsh as the default shell
if [ "$SHELL" != "$(which zsh)" ]; then
    echo "Changing the default shell to Zsh..."
    chsh -s $(which zsh)
    echo "Shell changed to Zsh. Please log out and log back in to apply the changes."
else
    echo "Zsh is already the default shell."
fi


