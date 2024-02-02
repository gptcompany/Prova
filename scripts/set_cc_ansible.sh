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
    - name: Get PostgreSQL config file location
      ansible.builtin.command: psql -U postgres -tA -c "SHOW config_file;"
      become: yes
      become_user: postgres
      register: pg_config_file
      changed_when: false

    - name: Set fact for pg_hba.conf directory
      set_fact:
        pg_hba_dir: "{{ pg_config_file.stdout | dirname }}"

    - name: Ensure TimescaleDB can accept connections
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "host all all {{ ansible_default_ipv4.address }}/32 trust"
      notify: reload postgresql

    - name: Ensure local access for PostgreSQL user
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "local all postgres trust"
      notify: reload postgresql

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
