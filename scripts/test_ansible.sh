#!/bin/bash

# Check for the correct number of arguments
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 TIMESCALEDB_VPC_IP"
    exit 1
fi

# Assign arguments to variables
TIMESCALEDB_VPC_IP=$1
AWS_SECRET_ID="ultimaec2key"

# Check if Ansible is installed, install if not
if ! command -v ansible > /dev/null; then
    echo "Ansible not found. Installing Ansible..."
    sudo apt-get update
    sudo apt-get install -y ansible
else
    echo "Ansible is already installed."
fi

# Fetch secret from AWS Secrets Manager
if command -v aws > /dev/null; then
    echo "Fetching SSH key from AWS Secrets Manager..."
    aws secretsmanager get-secret-value --secret-id $AWS_SECRET_ID --query 'SecretString' --output text | base64 --decode > $HOME/retrieved_key.pem
    chmod 600 $HOME/retrieved_key.pem
else
    echo "AWS CLI not found. Please install AWS CLI and configure it."
    exit 1
fi

# Create the Ansible playbook for configuring barman
cat <<EOF > $HOME/configure_barman_on_cc.yml
---
- name: Setup Barman for TimescaleDB Backup
  hosts: localhost
  become: yes
  vars:
    timescaledb_vpc_ip: "$TIMESCALEDB_VPC_IP"

  tasks:
    - name: Check if barman user exists
      command: id barman
      register: barman_user
      ignore_errors: yes

    - name: Install barman
      apt:
        name: barman
        state: present
      when: barman_user is failed

    - name: Ensure barman user exists
      user:
        name: barman
        system: yes
        create_home: yes
      when: barman_user is failed

    - name: Check for existing SSH public key for barman user
      stat:
        path: "/home/barman/.ssh/id_rsa.pub"
      register: ssh_key_stat
      become: true
      become_user: barman

    - name: Generate SSH key for barman user if not exists
      user:
        name: barman
        generate_ssh_key: yes
        ssh_key_file: "/home/barman/.ssh/id_rsa"
      when: not ssh_key_stat.stat.exists
      become: true
      become_user: barman

    - name: Ensure barman has no password in sudoers
      lineinfile:
        path: /etc/sudoers
        line: 'barman ALL=(ALL) NOPASSWD: ALL'
        validate: '/usr/sbin/visudo -cf %s'
EOF

# Create the Ansible playbook for SSH setup
cat <<EOF > $HOME/configure_ssh_from_cc.yml
---
- name: Setup SSH Access for ubuntu User
  hosts: localhost
  become: yes
  vars:
    timescaledb_vpc_ip: "$TIMESCALEDB_VPC_IP"
    ansible_ssh_private_key_file: "$HOME/retrieved_key.pem"

  tasks:
    - name: Check if SSH public key exists for ubuntu user
      stat:
        path: "/home/ubuntu/.ssh/id_rsa.pub"
      register: ssh_pub_key
      become: true
      become_user: ubuntu

    - name: Generate SSH key for ubuntu user if not exists
      user:
        name: ubuntu
        generate_ssh_key: yes
        ssh_key_file: "/home/ubuntu/.ssh/id_rsa"
      when: not ssh_pub_key.stat.exists
      become: true
      become_user: ubuntu

    - name: Fetch the public key
      slurp:
        src: "/home/ubuntu/.ssh/id_rsa.pub"
      register: ubuntu_ssh_pub_key
      become: true
      become_user: ubuntu

    - name: Ensure ubuntu user can SSH into TIMESCALEDB_VPC_IP
      authorized_key:
        user: ubuntu
        state: present
        key: "{{ ubuntu_ssh_pub_key.content | b64decode }}"
      delegate_to: "{{ timescaledb_vpc_ip }}"
      vars:
        ansible_user: ubuntu
        ansible_ssh_private_key_file: "{{ ansible_ssh_private_key_file }}"
EOF

echo "Playbooks created: configure_barman_on_cc.yml and configure_ssh_from_cc.yml"
echo "Proceed with running Ansible playbooks as needed."
ansible-playbook -vv $HOME/configure_barman_on_cc.yml
ansible-playbook -vv $HOME/configure_ssh_from_cc.yml
