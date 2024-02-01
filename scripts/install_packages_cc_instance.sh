#!/bin/bash
TIMESCALEDB_IP="57.181.106.64"
# User to SSH into TimescaleDB server
SSH_USER="postgres"
# Command to get the IP of the current server
LOCAL_IP=$(hostname -I | awk '{print $1}')
# Function to generate and display SSH key
generate_and_cat_ssh_key() {
    local user=$1
    local ssh_dir="$(eval echo ~$user)/.ssh"
    local ssh_key="$ssh_dir/id_rsa"

    sudo -u $user bash -c "mkdir -p $ssh_dir && chmod 700 $ssh_dir
    if [ ! -f $ssh_key ]; then
        yes y | ssh-keygen -t rsa -f $ssh_key -N ''
    fi
    echo '>>>>Displaying public SSH key for user: $user'
    cat $ssh_key.pub
    echo 'End of public SSH key for user: $user <<<<<<<'"
}


install_dependencies() {
if command -v apt-get &>/dev/null; then
        # Debian, Ubuntu, or other apt-based systems

        # install aws cli 2 if version 2 isn't installed?
        aws --version
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        aws --version
        # Check if AWS is configured
        if aws configure list; then
            echo "AWS is configured."
        else
            echo "AWS is not configured."
            sudo aws configure
        fi
        sudo apt-get update && sudo apt-get upgrade -y
        sudo apt-get install build-essential libpq-dev python3-dev curl wget rsync software-properties-common postgresql postgresql-contrib -y
        #install cluster controll by several nines and all his dependancies
        cd
        curl -L https://severalnines.com/downloads/cmon/install-cc -o install-cc
        chmod +x install-cc
        sudo ./install-cc
        #install barman
        sudo apt-get install barman -y
        sudo -i -u postgres
        createuser --interactive -P barman
    else
        echo "Package manager not supported. Install the packages manually."
    fi
}

# Main 
sudo chmod +x $HOME/statarb/scripts/install_terminal_ubuntu.sh
$HOME/statarb/scripts/install_terminal_ubuntu.sh
install_dependencies
# Generate and display SSH key for postgres
generate_and_cat_ssh_key "postgres"
# Generate and display SSH key for barman
generate_and_cat_ssh_key "barman"
# Generate and display SSH key for barman
generate_and_cat_ssh_key "ubuntu"
echo "copy the ssh key in sudo nano ~/.ssh/authorized_keys or sudo vi ~/.ssh/authorized_keys on the machine you want SSH into"
# wait for user to confirm that authorized_key are saved before continuing with the script
# test ssh connection to 
# SSH command to append to pg_hba.conf
SSH_COMMAND="grep -q -F 'host all all ${LOCAL_IP}/32 trust' /etc/postgresql/15/main/pg_hba.conf || echo 'host all all ${LOCAL_IP}/32 trust' | sudo tee -a /etc/postgresql/15/main/pg_hba.conf"
ssh ${SSH_USER}@${TIMESCALEDB_IP} "${SSH_COMMAND}"







