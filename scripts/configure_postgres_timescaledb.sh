#!/bin/bash
# Assign arguments to variables
TIMESCALEDB_PRIVATE_IP=$(aws ssm get-parameter --name TIMESCALEDB_PRIVATE_IP --with-decryption --query 'Parameter.Value' --output text)
TIMESCALEDB_PUBLIC_IP=$(aws ssm get-parameter --name TIMESCALEDB_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
STANDBY_PUBLIC_IP=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
ECS_INSTANCE_PRIVATE_IP=$(aws ssm get-parameter --name ECS_INSTANCE_PRIVATE_IP --with-decryption --query 'Parameter.Value' --output text)
ECS_INSTANCE_PUBLIC_IP=$(aws ssm get-parameter --name ECS_INSTANCE_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
AWS_SECRET_ID=$(aws ssm get-parameter --name sshkeypem --with-decryption --query 'Parameter.Value' --output text)
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
AWS_REGION=$(aws ssm get-parameter --name REGION --with-decryption --query 'Parameter.Value' --output text)
CLUSTERCONTROL_PRIVATE_IP=$(hostname -I | awk '{print $1}')
CLUSTERCONTROL_PUBLIC_IP=$(curl -s ifconfig.me)

# Create the Ansible playbook file
cat <<EOF > $HOME/configure_postgres_timescaledb.yml
- name: Configure PostgreSQL on TimescaleDB Server for WAL Streaming
  hosts: timescaledb_servers
  become: yes
  gather_facts: yes
  vars:
    barman_server_ip: "{{ clustercontrol_private_ip }}"


  tasks:
    - name: Fetch PostgreSQL configuration file path
      ansible.builtin.shell: |
        psql -t -U postgres -c "SHOW config_file"
      register: pg_config_file
      changed_when: false
      become_user: postgres
      when: "'internal' in hostvars[inventory_hostname]['role']"

    - name: Set the path as a fact
      set_fact:
        postgresql_conf_path: "{{ pg_config_file.stdout_lines[0].strip() }}"
      when: "'internal' in hostvars[inventory_hostname]['role']"

    - name: Update archive_command in postgresql.conf for WAL streaming
      ansible.builtin.lineinfile:
        path: "{{ postgresql_conf_path }}"
        regexp: '^archive_command ='
        line: "archive_command = 'rsync -e \"ssh -p 22\" -a %p barman@{{ barman_server_ip }}:{{ hostvars['localhost']['incoming_wals_dir'] }}/%f'"
        state: present
      when: "'internal' in hostvars[inventory_hostname]['role']"
      notify: restart postgresql
      
    - name: Adjust WAL settings in postgresql.conf
      ansible.builtin.lineinfile:
        path: "{{ postgresql_conf_path }}"
        regexp: '^[#]*\s*{{ item.key }}\s*='
        line: "{{ item.key }} = {{ item.value }}"
        state: present
      loop:
        - { key: "wal_keep_size", value: "512MB" }
        - { key: "max_wal_size", value: "1GB" }
        - { key: "wal_compression", value: "on" }
      when: "'internal' in hostvars[inventory_hostname]['role']"
      notify: restart postgresql

    
    - name: Configure relaxed autovacuum settings in postgresql.conf
      ansible.builtin.lineinfile:
        path: "{{ postgresql_conf_path }}"
        regexp: '^[#]*\s*{{ item.key }}\s*='
        line: "{{ item.key }} = {{ item.value }}"
        state: present
      loop:
        - { key: "autovacuum_naptime", value: "'5min'" }
        - { key: "autovacuum_vacuum_threshold", value: "100" }
        - { key: "autovacuum_analyze_threshold", value: "100" }
        - { key: "autovacuum_vacuum_scale_factor", value: "0.4" }
        - { key: "autovacuum_analyze_scale_factor", value: "0.2" }
        - { key: "autovacuum_max_workers", value: "2" }
      when: "'internal' in hostvars[inventory_hostname]['role']"
      notify: restart postgresql



  handlers:
    - name: restart postgresql
      ansible.builtin.service:
        name: postgresql
        state: restarted
      listen: "restart postgresql"

EOF
# Path to the inventory file
INVENTORY_FILE="$HOME/timescaledb_inventory.yml"
# Check if the inventory file exists, create if not
if [ ! -f "$INVENTORY_FILE" ]; then
    cat <<EOF > "$INVENTORY_FILE"
---
all:
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "\${HOME}/retrieved_key.pem"  # This will work because it's in a shell script
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
    #ansible_python_interpreter: /usr/bin/python3
  children:
    timescaledb_servers:
      hosts:
        timescaledb_private_server:
          ansible_host: "$TIMESCALEDB_PRIVATE_IP"  # Direct shell variable substitution
          role: internal
        timescaledb_public_server:
          ansible_host: "$TIMESCALEDB_PUBLIC_IP"  # Direct shell variable substitution
          role: external
        standby_server:
          ansible_host: "$STANDBY_PUBLIC_IP"  # Direct shell variable substitution
          role: external
    clustercontrol:
      hosts:
        clustercontrol_private_server:
          ansible_host: "$CLUSTERCONTROL_PRIVATE_IP"  # Direct shell variable substitution
          role: internal
        clustercontrol_public_server:
          ansible_host: "$CLUSTERCONTROL_PUBLIC_IP"  # Direct shell variable substitution
          role: external
    ecs:
      hosts:
        ecs_private_server:
          ansible_host: "$ECS_INSTANCE_PRIVATE_IP"  # Direct shell variable substitution
          ansible_user: ec2-user  # Specify the user for ECS instances
          role: internal
        ecs_public_server:
          ansible_host: "$ECS_INSTANCE_PUBLIC_IP"  # Direct shell variable substitution
          ansible_user: ec2-user  # Specify the user for ECS instances
          role: external
EOF
    echo "Inventory file created at $INVENTORY_FILE"
else
    echo "Inventory file already exists at $INVENTORY_FILE"
fi
# Install Barman and Barman-cli if not already installed
# sudo apt-get update
# sudo apt-get install -y barman barman-cli


# Set ACL for the barman user on /etc/barman.conf
# This ensures barman has the necessary permissions
# sudo setfacl -m u:barman:rw- /etc/barman.conf

# Run the Ansible playbook
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/configure_postgres_timescaledb.yml  -e "timescaledb_password=${TIMESCALEDBPASSWORD} clustercontrol_private_ip=${CLUSTERCONTROL_PRIVATE_IP}"