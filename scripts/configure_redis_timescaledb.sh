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
REDIS_PASSWORD=$(aws ssm get-parameter --name REDIS_PASSWORD --with-decryption --query 'Parameter.Value' --output text)

# Create the Ansible playbook for configuring Redis
cat <<EOF > $HOME/settings_redis_timescaledb.yml
---
- name: Configure Redis settings
  hosts: timescaledb_private_server
  gather_facts: yes
  become: yes
  vars:
    redis_conf_path: "/etc/redis/redis.conf"
    timescaledb_private_ip: "{{ timescaledb_private_ip }}"
    ecs_instance_private_ip: "{{ ecs_instance_private_ip }}"
    redis_password: "{{ REDIS_PASSWORD }}"
  tasks:
    - name: Update Redis configuration to bind specific IPs
      ansible.builtin.lineinfile:
        path: "{{ redis_conf_path }}"
        regexp: "^bind "
        line: "bind 127.0.0.1 {{ ecs_instance_private_ip }}"
        state: present

    - name: Set Redis requirepass configuration
      ansible.builtin.lineinfile:
        path: "{{ redis_conf_path }}"
        regexp: "^requirepass "
        line: "requirepass {{ redis_password }}"
        state: present

    - name: Enable TLS authentication for clients
      ansible.builtin.lineinfile:
        path: "{{ redis_conf_path }}"
        regexp: "^tls-auth-clients "
        line: "tls-auth-clients yes"
        state: present

  handlers:
    - name: restart redis
      ansible.builtin.service:
        name: redis
        state: restarted
EOF

echo "Redis configuration playbook created at: $HOME/settings_redis_timescaledb.yml"

# Create the Ansible playbook for configuring Redis
cat <<EOF > $HOME/configure_redis_timescaledb.yml
---
- name: Transfer Redis TLS Certificates from TimescaleDB to ECS Instance
  hosts: localhost
  gather_facts: no
  vars:
    timescaledb_private_ip: "$TIMESCALEDB_PRIVATE_IP"
    ecs_instance_private_ip: "$ECS_INSTANCE_PRIVATE_IP"
    redis_certificates:
      - { src: "/var/lib/redis/server.key", dest: "/home/ec2-user/server.key" }
      - { src: "/var/lib/redis/server.crt", dest: "/home/ec2-user/server.crt" }
      - { src: "/var/lib/redis/ca.crt", dest: "/home/ec2-user/ca.crt" }
    local_tmp_dir: "/tmp/redis-certs"
    ansible_user: "ubuntu"
    ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'

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
      become: yes
      delegate_to: "{{ timescaledb_private_ip }}"
      loop: "{{ redis_certificates }}"

    - name: Remove existing directories or files on ECS Instance before copying new ones
      ansible.builtin.file:
        path: "{{ item.dest }}"
        state: absent
      loop: "{{ redis_certificates }}"
      delegate_to: "{{ ecs_instance_private_ip }}"

    - name: Copy Redis certificates to ECS Instance
      ansible.builtin.copy:
        src: "{{ local_tmp_dir }}/{{ item.src | basename }}"
        dest: "{{ item.dest }}"
        owner: ec2-user
        group: ec2-user
        mode: '0644'
        force: yes
      loop: "{{ redis_certificates }}"
      delegate_to: "{{ ecs_instance_private_ip }}"
      vars:
        ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
        ansible_user: "ec2-user"

EOF

INVENTORY_FILE="$HOME/timescaledb_inventory.yml"
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
#ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ensure_remote_tmp.yml
ansible-playbook -v $HOME/configure_redis_timescaledb.yml -e "timescaledb_private_ip=$TIMESCALEDB_PRIVATE_IP ecs_instance_private_ip=$ECS_INSTANCE_PRIVATE_IP"
ansible-playbook -v -i "$HOME/timescaledb_inventory.yml" $HOME/settings_redis_timescaledb.yml -e "timescaledb_private_ip=$TIMESCALEDB_PRIVATE_IP ecs_instance_private_ip=$ECS_INSTANCE_PRIVATE_IP REDIS_PASSWORD=$REDIS_PASSWORD"
