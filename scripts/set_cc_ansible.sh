#!/bin/bash

# Check for the correct number of arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 TIMESCALEDB_IP STANDBY_IP SSH_USER_POSTGRES"
    exit 1
fi

# Assign arguments to variables
TIMESCALEDB_IP=$1
STANDBY_IP=$2
SSH_USER_POSTGRES=$3

# Echo variables for debugging
echo "TIMESCALEDB_IP: $TIMESCALEDB_IP"
echo "STANDBY_IP: $STANDBY_IP"
echo "SSH_USER_POSTGRES: $SSH_USER_POSTGRES"

# Check if Ansible is installed, install if not
if ! command -v ansible > /dev/null; then
    echo "Ansible not found. Installing Ansible..."
    sudo apt update
    sudo apt install -y ansible
else
    echo "Ansible is already installed."
fi

# Create the inventory file dynamically
cat <<EOF > $HOME/statarb/scripts/hosts.ini
[timescaledb_servers]
timescaledb_primary ansible_host=$TIMESCALEDB_IP ansible_user=$SSH_USER_POSTGRES
timescaledb_standby ansible_host=$STANDBY_IP ansible_user=$SSH_USER_POSTGRES
EOF

# Echo the path of hosts.ini for debugging
echo "Inventory file created at: $HOME/statarb/scripts/hosts.ini"

# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/statarb/scripts/configure_timescaledb.yml
---
- name: Configure TimescaleDB Servers
  hosts: timescaledb_servers
  become: yes
  tasks:
    - name: Get PostgreSQL data directory
      ansible.builtin.shell: |
        psql -t -A -c "SHOW data_directory;"  # Assumes the `postgres` user can run `psql` without password
      register: pg_data_dir
      changed_when: false

    - name: Ensure TimescaleDB can accept connections
      ansible.builtin.lineinfile:
        path: "{{ pg_data_dir.stdout }}/pg_hba.conf"
        line: "host replication all {{ ansible_default_ipv4.address }}/32 trust"
        state: present
      notify: reload postgresql

  handlers:
    - name: reload postgresql
      ansible.builtin.service:
        name: postgresql
        state: reloaded

EOF

# Echo the path of configure_timescaledb.yml for debugging
echo "Playbook file created at: $HOME/statarb/scripts/configure_timescaledb.yml"

# Execute the Ansible playbook
ansible-playbook -i $HOME/statarb/scripts/hosts.ini $HOME/statarb/scripts/configure_timescaledb.yml
