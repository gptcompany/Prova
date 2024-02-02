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
  become: yes  # This elevates privilege for the entire playbook; adjust as necessary for your environment

  tasks:
    - name: Get PostgreSQL data directory
      ansible.builtin.command: psql -U postgres -tA -c "SHOW data_directory;"
      become: yes  # Ensure this task is executed with elevated privileges
      become_user: postgres  # Specifies the user to become; uses 'sudo' under the hood
      register: pg_data_dir
      changed_when: false
      ignore_errors: true  # Optionally ignore errors if command execution is not crucial

    - name: Ensure TimescaleDB can accept connections
      ansible.builtin.lineinfile:
        path: "{{ pg_data_dir.stdout_lines[0] }}/pg_hba.conf"  # Adjusted to use stdout_lines for cleaner output handling
        line: "host replication all {{ ansible_default_ipv4.address }}/32 trust"
        state: present
      notify: reload postgresql
      when: pg_data_dir is succeeded  # Ensures this task runs only if the previous task succeeded

  handlers:
    - name: reload postgresql
      ansible.builtin.service:
        name: postgresql
        state: reloaded
      become: yes  # Privilege escalation may be required to restart the service


EOF

# Create an Ansible configuration file dynamically
cat <<EOF > $HOME/statarb/scripts/ansible_cc.cfg
[defaults]
remote_tmp = /tmp/.ansible/\${USER}/tmp
EOF

# Adjust playbook execution to use the new ansible.cfg
export ANSIBLE_CONFIG=$HOME/statarb/scripts/ansible_cc.cfg

# Echo the path of configure_timescaledb.yml for debugging
echo "Playbook file created at: $HOME/statarb/scripts/configure_timescaledb.yml"

# Execute the Ansible playbook
ansible-playbook -vvv -i $HOME/statarb/scripts/hosts.ini $HOME/statarb/scripts/configure_timescaledb.yml
