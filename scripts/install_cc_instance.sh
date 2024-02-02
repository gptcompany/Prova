#!/bin/bash
# AWS settings
S3_BUCKET="s3://timescaledbinstance"
INSTANCE_NAME="clustercontrol"
# Check if AWS CLI is installed and its version
if aws --version &>/dev/null; then
    echo "AWS CLI is already installed."
    CURRENT_VERSION=$(aws --version | cut -d/ -f2 | cut -d' ' -f1)
    REQUIRED_VERSION="2.0.0"  # Set your required minimum version here
    if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
        echo "Upgrading AWS CLI..."
        # Commands to upgrade AWS CLI
        sudo apt-get install unzip -y
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -o awscliv2.zip
        sudo ./aws/install --update
        sudo rm awscliv2.zip
    else
        echo "AWS CLI is up to date."
    fi
else
    echo "AWS CLI is not installed. Installing now..."
    # Commands to upgrade AWS CLI
    sudo apt-get install unzip -y
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -o awscliv2.zip
    sudo ./aws/install --update
    sudo rm awscliv2.zip
fi
# Check if AWS is configured
if aws configure list; then
    echo "AWS is configured."
else
    echo "AWS is not configured."
    aws configure
fi
# DISABLE REMOVE VOLUME ON TERMINATION
# Retrieve Instance IDs based on a specific tag value
InstanceIds=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

if [ -z "$InstanceIds" ]; then
    echo "No instances found with the Name tag value: $INSTANCE_NAME"
fi

# Iterate over each Instance ID
for InstanceId in $InstanceIds; do
    echo "Processing instance: $InstanceId"
    
    # Retrieve Block Device Mappings for the current Instance ID
    BlockDeviceMappings=$(aws ec2 describe-instances --instance-ids $InstanceId \
        --query "Reservations[].Instances[].BlockDeviceMappings[].DeviceName" \
        --output text)
    
    # Iterate over each Block Device Mapping
    for DeviceName in $BlockDeviceMappings; do
        echo "Setting DeleteOnTermination to false for $DeviceName on $InstanceId"
        
        # Modify DeleteOnTermination attribute
        aws ec2 modify-instance-attribute --instance-id $InstanceId \
            --block-device-mappings "[{\"DeviceName\": \"$DeviceName\", \"Ebs\": {\"DeleteOnTermination\": false}}]"
        
        if [ $? -eq 0 ]; then
            echo "Successfully modified $DeviceName on $InstanceId"
        else
            echo "Failed to modify $DeviceName on $InstanceId"
        fi
    done
done

# DISABLE UFW
sudo ufw disable
# Check if the statarb folder exists and update or clone the repo
if [ -d "$HOME/statarb" ]; then
    cd $HOME/statarb
    git pull origin main
else
    git clone https://github.com/gptcompany/statarb.git
fi
# SET 2GB SWAP
# Check for existing swap files
existing_swapfile=$(sudo swapon --show | awk 'NR>1 {print $1}')

if [ -n "$existing_swapfile" ]; then
    echo "An existing swap file $existing_swapfile is already active."
else
    # Create a new 2GB swap file
    sudo swapoff -a # Turn off existing swap file
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile

    # Add swap entry to /etc/fstab
    echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab

    # Verify the swap is active
    if [ -n "$(sudo swapon --show | awk 'NR>1 {print $1}')" ]; then
        echo "Swap file successfully created and activated."
    else
        echo "Failed to create and activate the swap file."
    fi
fi
# INSTALL PACKAGES AND TERMINAL (USING THE SCRIPT)
sudo chmod +x $HOME/statarb/scripts/install_packages_cc_instance.sh
$HOME/statarb/scripts/install_packages_cc_instance.sh

# function to copy from s3 the config files after confirmation of the user
echo "This will recover standby settings from S3. Do you want to continue? (y/n)"
read -r confirmation

if [[ $confirmation == "y" || $confirmation == "Y" ]]; then
    sudo chmod +x $HOME/statarb/scripts/recover_standby_settings.sh
    $HOME/statarb/scripts/recover_standby_settings.sh
else
    echo "Recovery settings process aborted."
fi




