#!/bin/bash

$INSTANCE_NAME="clustercontrol"
# Check if AWS is configured
if aws configure list; then
    echo "AWS is configured."
else
    echo "AWS is not configured."
    sudo aws configure
fi
# DISABLE REMOVE VOLUME ON TERMINATION
InstanceId=$(aws ec2 describe-instances --filters "Name=key-name,Values=$INSTANCE_NAME" --query "Reservations[].Instances[].[InstanceId]" --output text)
# Assuming there's only one instance ID returned above, otherwise this approach needs adjustment for multiple IDs
DeviceName=$(aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[].Instances[].BlockDeviceMappings[].DeviceName' --output text)
aws ec2 modify-instance-attribute --instance-id $InstanceId --block-device-mappings "[{\"DeviceName\": \"$DeviceName\",\"Ebs\":{\"DeleteOnTermination\":false}}]"
# DISABLE UFW
sudo ufw disable
# CLONE STATARB
git clone https://github.com/gptcompany/statarb.git
# Check if the terminal-profile folder exists and update or clone the repo
if [ -d "$HOME/terminal-profile" ]; then
    cd $HOME/terminal-profile
    git pull origin main
else
    git clone https://github.com/gptcompany/statarb.git
fi
sudo chmod +x $HOME/startarb/scripts/install_packages_cc_instance.sh
$HOME/startarb/scripts/install_packages_cc_instance.sh



