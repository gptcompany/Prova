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
cat <<EOF > $HOME/configure_barman.yml
---
- name: Configure Barman on localhost with ACL for barman user
  hosts: localhost
  connection: local
  become: yes
  gather_facts: no
  vars:
    timescaledb_private_ip: "{{ TIMESCALEDB_PRIVATE_IP }}"
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
      backup_options = concurrent_backup

      [timescaledb]
      description = "Timescaledb Server"
      ssh_command = ssh postgres@{{ timescaledb_private_ip }}
      conninfo = host={{ timescaledb_private_ip }} user=postgres password={{ timescaledb_password }}
      retention_policy_mode = auto
      wal_retention_policy = main
      backup_options = concurrent_backup

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
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/configure_barman.yml  -e "timescaledb_private_ip=${TIMESCALEDB_PRIVATE_IP} timescaledb_password=${TIMESCALEDBPASSWORD} clustercontrol_private_ip=${CLUSTERCONTROL_PRIVATE_IP}"
