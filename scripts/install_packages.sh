#!/bin/bash

install_dependencies() {
    if command -v dnf &>/dev/null; then
        # Fedora, CentOS, or other dnf-based systems
        sudo dnf install util-linux-user -y
        sudo dnf groupinstall "Development Tools" -y
        sudo dnf install postgresql-devel -y
        sudo dnf install python3-devel -y
    elif command -v yum &>/dev/null; then
        # Older versions of CentOS, RHEL, or other yum-based systems
        sudo yum install util-linux-user -y
        sudo yum groupinstall "Development Tools" -y
        sudo yum install postgresql-devel -y
        sudo yum install python3-devel -y
    elif command -v apt-get &>/dev/null; then
        # Debian, Ubuntu, or other apt-based systems
        sudo apt-get install build-essential -y
        sudo apt-get install libpq-dev -y
        sudo apt-get install python3-dev -y
    else
        echo "Package manager not supported. Install the packages manually."
    fi
}

# Call the function
install_dependencies

#ADD
#pip3 install psycopg2 python-dateutil
#sudo yum install git python3-pip
#sudo yum install postgresql15-server
#sudo ln -sf /usr/bin/python3 /usr/bin/python
# install ip configure or something like that to upload the ip to the service timescaledb.mywire.org dynu




