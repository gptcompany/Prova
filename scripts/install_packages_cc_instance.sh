#!/bin/bash
TIMESCALEDB_IP="57.181.106.64"
STANDBY_IP="timescaledb.mywire.org"
# User to SSH into TimescaleDB server
SSH_USER_POSTGRES="postgres"
export TIMESCALEDB_IP STANDBY_IP SSH_USER_POSTGRES
# Identify the key binary or service to check for ClusterControl's presence.
CLUSTERCONTROL_BINARY="/usr/bin/cmon"
CLUSTERCONTROL_SERVICE="cmon" # Adjust the service name based on your setup.
# Command to get the IP of the current server
LOCAL_IP=$(hostname -I | awk '{print $1}')
# Function to generate and display SSH key
generate_and_cat_ssh_key() {
    local user=$1
    local ssh_dir

    if [ "$user" = "postgres" ]; then
        ssh_dir="/var/lib/postgresql/.ssh"
    elif [ "$user" = "barman" ]; then
        # Get the home directory of the barman user
        ssh_dir="$(getent passwd barman | cut -d: -f6)/.ssh"
    else
        ssh_dir="$(eval echo ~$user)/.ssh"
    fi

    sudo mkdir -p $ssh_dir
    sudo chown $user:$user $ssh_dir
    sudo chmod 700 $ssh_dir
    local ssh_key="$ssh_dir/id_rsa"

    if [ ! -f $ssh_key ]; then
        sudo -u $user ssh-keygen -t rsa -f $ssh_key -N ''
    fi

    echo ">>>>Displaying public SSH key for user: $user"
    sudo -u $user cat $ssh_key.pub
    echo "End of public SSH key for user: $user <<<<<<<"
}
# Function to check if ClusterControl is installed via package manager
check_clustercontrol_package() {
    if which apt > /dev/null; then
        # For Debian/Ubuntu systems
        dpkg -l | grep -qw cmon && return 0
    elif which yum > /dev/null; then
        # For RHEL/CentOS systems
        yum list installed | grep -qw cmon && return 0
    fi
    return 1
}

# Function to find ClusterControl binary
find_clustercontrol_binary() {
    local binary=$(which cmon 2>/dev/null)
    if [ ! -z "$binary" ]; then
        echo "$binary"
        return 0
    else
        # Fallback: Check common installation paths
        for path in /usr/bin/cmon /usr/local/bin/cmon; do
            if [ -x "$path" ]; then
                echo "$path"
                return 0
            fi
        done
    fi
    return 1
}

# Check if ClusterControl package is installed
if check_clustercontrol_package; then
    echo "ClusterControl package is installed."
else
    echo "ClusterControl package is not installed."
fi



install_dependencies() {
    if command -v apt-get &>/dev/null; then
        # Debian, Ubuntu, or other apt-based systems
        # Check if AWS CLI is installed and its version
        if aws --version &>/dev/null; then
            echo "AWS CLI is already installed."
            CURRENT_VERSION=$(aws --version | cut -d/ -f2 | cut -d' ' -f1)
            REQUIRED_VERSION="2.0.0"  # Set your required minimum version here
            if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
                echo "Upgrading AWS CLI..."
                # Commands to upgrade AWS CLI
                curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
                unzip -o awscliv2.zip
                sudo ./aws/install --update
            else
                echo "AWS CLI is up to date."
            fi
        else
            echo "AWS CLI is not installed. Installing now..."
            # Commands to install AWS CLI
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
            unzip -o awscliv2.zip
            sudo ./aws/install
        fi

        # Check if AWS is configured
        if aws configure list; then
            echo "AWS is configured."
        else
            echo "AWS is not configured."
            sudo aws configure
        fi
        sudo apt-get update && sudo apt-get upgrade -y
        sudo apt-get install build-essential libpq-dev python3-dev curl wget rsync software-properties-common postgresql postgresql-contrib -y
        # INSTALL BARMAN
        sudo apt-get install barman -y
        # Check if barman user exists, and create if it does not
        if id "barman" &>/dev/null; then
            echo "Barman user already exists"
        else
            sudo adduser --system --group --home /home/barman barman
            echo "Barman user created"
        fi
    else
        echo "Package manager not supported. Install the packages manually."
    fi
}

# Main 
install_dependencies
# Attempt to find the ClusterControl binary
CLUSTERCONTROL_BINARY=$(find_clustercontrol_binary)
if [ $? -eq 0 ]; then
    echo "Found ClusterControl binary at $CLUSTERCONTROL_BINARY."
else
    echo "ClusterControl binary not found. Installing ClusterControl..."

    # Download and install ClusterControl
    cd || exit # Ensures that the script exits if changing directory fails.
    curl -L https://severalnines.com/downloads/cmon/install-cc -o install-cc
    chmod +x install-cc
    sudo ./install-cc
fi

# Generate and display SSH key for postgres
#generate_and_cat_ssh_key "postgres"
# Generate and display SSH key for barman
generate_and_cat_ssh_key "barman"
# Generate and display SSH key for barman
generate_and_cat_ssh_key "ubuntu"
echo "copy the ssh key in sudo nano ~/.ssh/authorized_keys or sudo vi ~/.ssh/authorized_keys on the machine you want SSH into (main and standby for all users you want connect (ubuntu, ec2-user, postgres))"
echo "use sudo su - postgres, cd /var/lib/postgresql/.ssh , mkdir -p ./.ssh (if doesn't exist), chmod 700 ./.ssh, echo "" >> authorized_keys , chmod 600 ./authorized_keys"
echo "use sudo su - barman, mkdir -p ~/.ssh , chmod 700 ~/.ssh , echo "" >> ~/.ssh/authorized_keys , chmod 600 ~/.ssh/authorized_keys "
# wait for user to confirm that authorized_key are saved before continuing with the script
read -p "Press Enter once the SSH key is saved in authorized_keys and tried to ssh into users..."
read -p "Press Enter once again..."
# Test SSH connection
echo "Testing SSH connection to ${SSH_USER_POSTGRES}@${TIMESCALEDB_IP}..."
ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER_POSTGRES}@${TIMESCALEDB_IP} "echo 'SSH connection successful'"
if [ $? -ne 0 ]; then
    echo "SSH connection failed. Please check your settings."
    read -p "Press Enter once the SSH key is saved in authorized_keys..."
fi
# SSH command to append to pg_hba.conf
SSH_COMMAND="grep -q -F 'host all all ${LOCAL_IP}/32 trust' /etc/postgresql/15/main/pg_hba.conf || echo 'host all all ${LOCAL_IP}/32 trust' | sudo tee -a /etc/postgresql/15/main/pg_hba.conf"
ssh ${SSH_USER_POSTGRES}@${TIMESCALEDB_IP} "${SSH_COMMAND}"

echo "Testing SSH connection to ${SSH_USER_POSTGRES}@${STANDBY_IP}..."
ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER_POSTGRES}@${STANDBY_IP} "echo 'SSH connection successful'"
if [ $? -ne 0 ]; then
    echo "SSH connection failed. Please check your settings."
    read -p "Press Enter once the SSH key is saved in authorized_keys..."
fi
# SSH command to append to pg_hba.conf
SSH_COMMAND="grep -q -F 'host all all ${LOCAL_IP}/32 trust' /etc/postgresql/15/main/pg_hba.conf || echo 'host all all ${LOCAL_IP}/32 trust' | sudo tee -a /etc/postgresql/15/main/pg_hba.conf"
ssh ${SSH_USER_POSTGRES}@${STANDBY_IP} "${SSH_COMMAND}"

sudo su - barman
mkdir -p $HOME/.ssh
chmod 700 $HOME/.ssh
REMOTE_KEY=$(ssh ${SSH_USER_POSTGRES}@${STANDBY_IP} "cat ~/.ssh/id_rsa.pub")
# On the local machine, append the key to authorized_keys
echo "$REMOTE_KEY" >> ~/.ssh/authorized_keys
REMOTE_KEY=$(ssh ${SSH_USER_POSTGRES}@${TIMESCALEDB_IP} "cat ~/.ssh/id_rsa.pub")
# On the local machine, append the key to authorized_keys
echo "$REMOTE_KEY" >> $HOME/.ssh/authorized_keys
chmod 600 $HOME/.ssh/authorized_keys
sudo su - ubuntu
# INSTALL ZSH
sudo chmod +x $HOME/statarb/scripts/install_terminal_ubuntu.sh
$HOME/statarb/scripts/install_terminal_ubuntu.sh






