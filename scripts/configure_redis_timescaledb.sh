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
cat <<EOF > $HOME/configure_redis_timescaledb.yml
---
- name: Transfer Redis TLS Certificates from TimescaleDB to ECS Instance
  hosts: localhost
  gather_facts: no
  vars:
    timescaledb_private_ip: "{{ lookup('env', 'TIMESCALEDB_PRIVATE_IP') }}"
    ecs_instance_private_ip: "{{ lookup('env', 'ECS_INSTANCE_PRIVATE_IP') }}"
    redis_certificates:
      - { src: "/var/lib/redis/server.key", dest: "/home/ubuntu/server.key" }
      - { src: "/var/lib/redis/server.crt", dest: "/home/ubuntu/server.crt" }
      - { src: "/var/lib/redis/ca.crt", dest: "/home/ubuntu/redis/ca.crt" }
    local_tmp_dir: "/tmp/redis-certs"

  tasks:
    - name: Ensure local temporary directory exists
      ansible.builtin.file:
        path: "{{ local_tmp_dir }}"
        state: directory

    - name: Fetch Redis certificates from TimescaleDB server
      ansible.builtin.fetch:
        src: "{{ item.src }}"
        dest: "{{ local_tmp_dir }}/"
        flat: yes
      delegate_to: "{{ timescaledb_private_ip }}"
      loop: "{{ redis_certificates }}"

    - name: Copy Redis certificates to ECS Instance
      ansible.builtin.copy:
        src: "{{ local_tmp_dir }}/{{ item.src | basename }}"
        dest: "{{ item.dest }}"
        owner: ubuntu
        group: ubuntu
        mode: '0644'
        force: yes  # This ensures the file is overwritten if it already exists
      delegate_to: "{{ ecs_instance_private_ip }}"
      loop: "{{ redis_certificates }}"

    - name: Clean up local temporary directory
      ansible.builtin.file:
        path: "{{ local_tmp_dir }}"
        state: absent

EOF
echo "Playbook file created at: $HOME/configure_redis_timescaledb.yml"
# Create an Ansible configuration file with a fixed temporary directory
cat <<EOF > $HOME/ansible_cc.cfg
[defaults]
remote_tmp = /var/tmp/ansible-tmp
# ansible_python_interpreter: /usr/lib/python3
EOF
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
export ANSIBLE_CONFIG=$HOME/ansible_cc.cfg
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ensure_remote_tmp.yml
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/configure_redis_timescaledb.yml
