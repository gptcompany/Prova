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
- name: Configure Barman on localhost with ACL for barman user
  hosts: localhost
  connection: local
  become: yes
  gather_facts: no
  tasks:
    - name: Get Barman server info for 'timescaledb'
      ansible.builtin.command: "barman show-server timescaledb"
      register: barman_server_info
      ignore_errors: yes

    - name: Print Barman server info output
      ansible.builtin.debug:
        var: barman_server_info.stdout

    - name: Extract incoming WALs directory path using shell
      ansible.builtin.shell: |
        echo "{{ barman_server_info.stdout }}" | grep 'incoming_wals_directory' | awk '{print $2}'
      register: extracted_path
      changed_when: false


    - name: Set incoming_wals_dir fact from extracted path correctly
      set_fact:
        incoming_wals_dir: "{{ extracted_path.stdout.split(':').1.strip() }}"


    - name: Debug print incoming WALs directory path
      ansible.builtin.debug:
        msg: "Incoming WALs directory path: {{ incoming_wals_dir }}"


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

# Modified playbook for configuring pg_hba.conf
cat <<EOF > $HOME/configure_postgres_timescaledb_servers.yml
---
- name: Configure pg_hba_conf in TimescaleDB Servers to allow specific IPs
  hosts: timescaledb_servers
  become: yes

  vars:
    ecs_instance_private_ip: "$ECS_INSTANCE_PRIVATE_IP"
    clustercontrol_public_ip: "$CLUSTERCONTROL_PUBLIC_IP"
    clustercontrol_private_ip: "$CLUSTERCONTROL_PRIVATE_IP"

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

    - name: Ensure TimescaleDB can accept connections from ECS instance private IP
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "host all all {{ ecs_instance_private_ip }}/32 trust"
      notify: reload postgresql

    - name: Ensure TimescaleDB can accept connections from ClusterControl public IP
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "host all all {{ clustercontrol_public_ip }}/32 trust"
      notify: reload postgresql

    - name: Ensure TimescaleDB can accept connections from ClusterControl private IP
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "host all all {{ clustercontrol_private_ip }}/32 trust"
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
      become: yes

EOF

# Echo the path of configure_pg_hba_conf_timescaledb_servers.yml for debugging
echo "pg_hba_conf configuration playbook created at: $HOME/configure_postgres_timescaledb_servers.yml"
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
# Playbook to ensure the temporary directory exists on remote hosts
cat <<EOF > $HOME/ensure_remote_tmp.yml
---
- name: Ensure Ansible temporary directory exists on all hosts
  hosts: all
  become: yes
  tasks:
    - name: Create Ansible temporary directory
      file:
        path: "/var/tmp/ansible-tmp"
        state: directory
        mode: '777'
EOF
# Install Barman and Barman-cli if not already installed
# sudo apt-get update
# sudo apt-get install -y barman barman-cli


# Set ACL for the barman user on /etc/barman.conf
# This ensures barman has the necessary permissions
# sudo setfacl -m u:barman:rw- /etc/barman.conf
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ensure_remote_tmp.yml
export ANSIBLE_CONFIG=$HOME/ansible_cc.cfg
echo "Using Ansible configuration file at: $ANSIBLE_CONFIG"
# Run the Ansible playbook
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/configure_postgres_timescaledb.yml  -e "timescaledb_password=${TIMESCALEDBPASSWORD} clustercontrol_private_ip=${CLUSTERCONTROL_PRIVATE_IP}"
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_postgres_timescaledb_servers.yml -e "ecs_instance_private_ip=$ECS_INSTANCE_PRIVATE_IP clustercontrol_public_ip=$CLUSTERCONTROL_PUBLIC_IP clustercontrol_private_ip=$CLUSTERCONTROL_PRIVATE_IP"