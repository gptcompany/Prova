#!/bin/bash
# Assign arguments to variables
TIMESCALEDB_PRIVATE_IP="172.31.35.73"
TIMESCALEDB_PUBLIC_IP="57.181.106.64"
STANDBY_PUBLIC_IP="timescaledb.mywire.org"
ECS_INSTANCE_PRIVATE_IP="172.31.38.68"
ECS_INSTANCE_PUBLIC_IP="52.193.34.34"
AWS_SECRET_ID="sshkeypem"
TIMESCALEDBPASSWORD="timescaledbpassword"
AWS_REGION="ap-northeast-1"
CLUSTERCONTROL_PRIVATE_IP=$(hostname -I | awk '{print $1}')
CLUSTERCONTROL_PUBLIC_IP=$(curl -s ifconfig.me)


# Create the Ansible playbook file
cat <<EOF > $HOME/configure_barman.yml
---
- name: Configure Barman on localhost with ACL for barman user
  hosts: localhost
  connection: local
  become: yes
  gather_facts: no
  vars:
    barman_conf_path: /etc/barman.conf
    barman_settings: |
      [barman]
      barman_user = barman
      configuration_files_directory = /etc/barman.d
      reuse_backup = link
      minimum_redundancy = 1
      barman_home = /var/lib/barman
      log_file = /var/lib/barman/barman.log
      log_level = INFO
      compression = pigz
      parallel_jobs = 3
      backup_directory = /var/lib/barman/backups
      backup_method = rsync
      wal_retention_policy = main
      retention_policy_mode = auto
      archiver = on

      [timescaledb]
      description = "Timescaledb Server"
      ssh_command = ssh postgres@172.31.35.73
      conninfo = host=172.31.35.73 user=postgres password={{ timescaledb_password }}
      retention_policy_mode = auto
      wal_retention_policy = main
  tasks:
    - name: Ensure barman.conf exists
      ansible.builtin.file:
        path: "{{ barman_conf_path }}"
        state: touch

    - name: Configure Barman settings
      ansible.builtin.blockinfile:
        path: "{{ barman_conf_path }}"
        block: "{{ barman_settings }}"
        marker: "# {mark} ANSIBLE MANAGED BLOCK"

    - name: Set ACL for barman user on barman.conf
      ansible.posix.acl:
        path: "{{ barman_conf_path }}"
        entity: barman
        etype: user
        permissions: rw
        state: present

    - name: Verify Barman configuration
      ansible.builtin.command:
        cmd: barman check all
      become: yes  # Enables privilege escalation
      become_user: barman  # Specifies the user to become
      register: barman_check
      ignore_errors: yes

    - name: Report Barman check failure
      ansible.builtin.debug:
        msg: "Barman configuration check failed. Please review the configuration."
      when: (barman_check is defined) and (barman_check.failed | default(false))

    
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
if command -v aws > /dev/null; then
    echo "Fetching TimescaleDB password from AWS Systems Manager Parameter Store..."
    TIMESCALEDBPASSWORD_RETRIEVED=$(aws ssm get-parameter --name "$TIMESCALEDBPASSWORD" --with-decryption --query 'Parameter.Value' --output text)
    
else
    echo "AWS CLI not found. Please install AWS CLI and configure it."
    exit 1
fi
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/configure_barman.yml  -e "timescaledb_password=${TIMESCALEDBPASSWORD_RETRIEVED} clustercontrol_private_ip=${CLUSTERCONTROL_PRIVATE_IP}""
