#!/bin/bash

# Source the variables from the first script
#source $HOME/statarb/scripts/install_packages_cc_instance.sh

# Echo variables for debugging
echo "TIMESCALEDB_IP: $TIMESCALEDB_IP"
echo "STANDBY_IP: $STANDBY_IP"
echo "SSH_USER_POSTGRES: $SSH_USER_POSTGRES"

if [ -z "$TIMESCALEDB_IP" ] || [ -z "$STANDBY_IP" ] || [ -z "$SSH_USER_POSTGRES" ]; then
    echo "One or more variables are undefined."
    echo "Please source install_packages_cc_instance.sh or define TIMESCALEDB_IP, STANDBY_IP, SSH_USER_POSTGRES."
    exit 1
fi

# Check if Ansible is installed, install if not
if ! command -v ansible > /dev/null; then
    sudo apt update
    sudo apt install -y ansible
fi

# Create the inventory file dynamically
cat <<EOF > hosts.ini
[timescaledb_servers]
timescaledb_primary ansible_host=$TIMESCALEDB_IP ansible_user=$SSH_USER_POSTGRES
timescaledb_standby ansible_host=$STANDBY_IP ansible_user=$SSH_USER_POSTGRES
EOF

# Create the Ansible playbook file dynamically
cat <<EOF > configure_timescaledb.yml
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

# Execute the Ansible playbook
ansible-playbook -i hosts.ini configure_timescaledb.yml
