#!/bin/bash

# Check for the correct number of arguments
# if [ "$#" -ne 1 ]; then
#     echo "Usage: $0 TIMESCALEDB_PRIVATE_IP"
#     exit 1
# fi

# Assign arguments to variables
TIMESCALEDB_PRIVATE_IP="172.31.35.73"
TIMESCALEDB_PUBLIC_IP="57.181.106.64"
CLUSTERCONTROL_PRIVATE_IP="172.31.32.75"
CLUSTERCONTROL_PUBLIC_IP="43.207.147.235"
STANDBY_PUBLIC_IP="timescaledb.mywire.org"
ECS_INSTANCE_PRIVATE_IP="172.31.38.68"
ECS_INSTANCE_PUBLIC_IP="52.193.34.34"
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
# Generate Ansible playbook for installing acl
cat <<EOF > $HOME/install_acl.yml
---
- name: Install ACL on local machine
  hosts: localhost
  become: yes
  tasks:
    - name: Ensure ACL is installed
      apt:
        name: acl
        state: present
- name: Install ACL on target machines
  hosts: all
  become: yes
  tasks:
    - name: Ensure ACL is installed
      apt:
        name: acl
        state: present
EOF

# Generate Ansible playbook for configuring barman
cat <<EOF > $HOME/configure_barman_on_cc.yml
---
- name: Setup Barman for TimescaleDB Backup
  hosts: localhost
  become: yes
  vars:
    timescaledb_PRIVATE_ip: "$TIMESCALEDB_PRIVATE_IP"

  tasks:
    - name: Check if barman user exists
      command: id barman
      register: barman_user
      ignore_errors: yes

    - name: Install barman
      apt:
        name: barman
        state: present
      when: barman_user.rc != 0

    - name: Ensure barman user exists
      user:
        name: barman
        system: yes
        create_home: no
      when: barman_user.rc != 0

    - name: Check for existing SSH public key for barman user
      stat:
        path: "/var/lib/barman/.ssh/id_rsa.pub"
      register: ssh_key_stat

    - name: Ensure .ssh directory exists for barman user
      file:
        path: "/var/lib/barman/.ssh"
        state: directory
        owner: barman
        group: barman
        mode: '0644'
      when: barman_user.rc != 0

    - name: Generate SSH key for barman user if not exists
      user:
        name: barman
        generate_ssh_key: yes
        ssh_key_file: "/var/lib/barman/.ssh/id_rsa"
      when: ssh_key_stat.stat.exists == false and barman_user.rc != 0

    - name: Ensure barman and ubuntu have no password in sudoers
      lineinfile:
        path: /etc/sudoers
        line: "{{ item }}"
        validate: '/usr/sbin/visudo -cf %s'
      loop:
        - 'barman ALL=(ALL) NOPASSWD: ALL'
        - 'ubuntu ALL=(ALL) NOPASSWD: ALL'
EOF

# Create the playbook to modify sudoers
cat <<EOF > $HOME/modify_sudoers.yml
---
- name: Update sudoers for ubuntu and postgres users
  hosts: all
  gather_facts: no
  become: yes
  tasks:
    - name: Ensure ubuntu user can run all commands without a password
      lineinfile:
        path: /etc/sudoers.d/ubuntu
        line: 'ubuntu ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
    - name: Ensure postgres user has necessary sudo privileges
      lineinfile:
        path: /etc/sudoers.d/postgres
        line: 'postgres ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
EOF

# Create the playbook for SSH setup
cat <<EOF > $HOME/configure_ssh_from_cc.yml
---
- name: Setup SSH Key for ubuntu User Locally and Authorize on Servers
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Check if SSH public key exists for ubuntu user
      stat:
        path: "{{ lookup('env', 'HOME') }}/.ssh/id_rsa.pub"
      register: ssh_pub_key
    - name: Generate SSH key for ubuntu user if not exists
      user:
        name: ubuntu
        generate_ssh_key: yes
        ssh_key_file: "{{ lookup('env', 'HOME') }}/.ssh/id_rsa"
      when: ssh_pub_key.stat.exists == false

- name: Setup SSH Access for ubuntu User on TimescaleDB Servers
  hosts: timescaledb_servers
  gather_facts: no
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  tasks:
    - name: Fetch the public key of ubuntu user
      slurp:
        src: "{{ lookup('env','HOME') }}/.ssh/id_rsa.pub"
      register: ubuntu_ssh_pub_key
      delegate_to: localhost

    - name: Ensure ubuntu user can SSH into each server without a password
      authorized_key:
        user: ubuntu
        state: present
        key: "{{ ubuntu_ssh_pub_key.content | b64decode }}"

- name: Ensure SSH public key is readable by all
  hosts: localhost
  gather_facts: no
  become: yes
  become_user: root
  tasks:
    - name: Set file permissions for id_rsa.pub
      file:
        path: /var/lib/barman/.ssh/id_rsa.pub
        mode: '0644'
    
    - name: Set ACL for ubuntu user on /var/lib/barman
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:rx /var/lib/barman

    - name: Set ACL for ubuntu user on /var/lib/barman/.ssh
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:rx /var/lib/barman/.ssh

    - name: Set ACL for ubuntu user on /var/lib/barman/.ssh/id_rsa.pub
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:r /var/lib/barman/.ssh/id_rsa.pub

    - name: Verify /var/lib/barman/.ssh/id_rsa.pub
      ansible.builtin.command:
        cmd: getfacl /var/lib/barman/.ssh/id_rsa.pub



- name: Check read /var/lib/barman/.ssh/id_rsa.pub
  hosts: localhost
  become: true
  become_user: ubuntu
  tasks:
    - name: Test read access to Barman's SSH public key
      ansible.builtin.shell:
        cmd: test -r /var/lib/barman/.ssh/id_rsa.pub && echo "ubuntu can read the file" || echo "ubuntu cannot read the file"
      register: read_test_result
      ignore_errors: true

    - name: Show test result
      ansible.builtin.debug:
        var: read_test_result.stdout

- name: Slurp Barman's SSH public key and decode
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Slurp Barman's SSH public key ##########################################################
      ansible.builtin.slurp:
        src: /var/lib/barman/.ssh/id_rsa.pub
      register: barman_ssh_key_slurped

    - name: Decode and store Barman's SSH public key
      set_fact:
        barman_ssh_key: "{{ barman_ssh_key_slurped['content'] | b64decode }}"

    # - name: Debug barman_ssh_key
    #   debug:
    #     var: barman_ssh_key

# - name: Debug - Show barman_ssh_key
#   hosts: localhost
#   gather_facts: no
#   tasks:
#     - name: Debug barman_ssh_key
#       debug:
#         var: barman_ssh_key

# - name: Use variable on other hosts DEBUG
#   hosts: timescaledb_servers
#   tasks:
#     - name: Use barman_ssh_key
#       debug:
#         msg: "Using SSH Key: {{ hostvars['localhost']['barman_ssh_key'] }}"


- name: Setup postgres on timescaledb servers
  hosts: timescaledb_servers
  become: yes
  tasks:
    - name: Check if postgres user exists
      command: id postgres
      register: postgres_user
      ignore_errors: yes

    - name: Ensure postgres user exists
      user:
        name: postgres
        system: yes
        create_home: no
      when: postgres_user.rc != 0

    - name: Check for existing SSH public key for postgres user
      stat:
        path: "/var/lib/postgresql/.ssh/id_rsa.pub"
      register: ssh_key_postgres

    - name: Ensure .ssh directory exists for postgres user
      file:
        path: "/var/lib/postgresql/.ssh"
        state: directory
        owner: postgres
        group: postgres
        mode: '0644'
      when: postgres_user.rc != 0

    - name: Generate SSH key for postgres user if not exists 
      user:
        name: postgres
        generate_ssh_key: yes
        ssh_key_file: "/var/lib/postgresql/.ssh/id_rsa"
      when: ssh_key_postgres.stat.exists == false

- name: Ensure SSH public key and related directories are properly accessible on TimescaleDB servers
  hosts: timescaledb_servers
  gather_facts: no
  become: yes
  become_user: root
  tasks:
    - name: Set file permissions for id_rsa.pub for postgres user
      file:
        path: /var/lib/postgresql/.ssh/id_rsa.pub
        mode: '0644'

    - name: Set ACL for ubuntu user on /var/lib/postgresql
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:rx /var/lib/postgresql

    - name: Set ACL for ubuntu user on /var/lib/postgresql/.ssh
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:rx /var/lib/postgresql/.ssh

    - name: Set ACL for ubuntu user on /var/lib/postgresql/.ssh/id_rsa.pub
      ansible.builtin.command:
        cmd: setfacl -m u:ubuntu:r /var/lib/postgresql/.ssh/id_rsa.pub

    - name: Verify /var/lib/postgresql/.ssh/id_rsa.pub permissions
      ansible.builtin.command:
        cmd: getfacl /var/lib/postgresql/.ssh/id_rsa.pub
      register: acl_check

    - name: Show ACL settings for /var/lib/postgresql/.ssh/id_rsa.pub
      debug:
        msg: "{{ acl_check.stdout }}"

- name: Authorize Barman's SSH Key for Postgres User on Remote Servers
  hosts: timescaledb_servers
  gather_facts: no
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env','HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  tasks:
    - name: "Ensure Postgres user can SSH into each server without a password"
      authorized_key:
        user: postgres
        key: "{{ hostvars['localhost']['barman_ssh_key'] }}" #"{{ barman_ssh_key }}"
        state: present
      become: yes
      become_user: postgres

- name: Gather the public SSH key of the postgres user
  hosts: timescaledb_servers
  become: yes
  become_user: postgres
  tasks:
    - name: Slurp the public SSH key of the postgres user
      slurp:
        src: "/var/lib/postgresql/.ssh/id_rsa.pub"
      register: postgres_pub_key

    - name: Register the public key as a variable
      set_fact:
        postgres_public_key: "{{ postgres_pub_key['content'] | b64decode }}"

- name: Authorize postgres public key on barman user's account
  hosts: localhost # Or the specific host where the barman user is located
  become: yes
  become_user: barman # Make sure this matches the user under which barman runs
  tasks:
    - name: Authorize SSH key for postgres user
      authorized_key:
        user: barman
        key: "{{ hostvars[item]['postgres_public_key'] }}"
        state: present
      loop: "{{ groups['timescaledb_servers'] }}"


EOF

# Generate the Ansible inventory
cat <<EOF > $HOME/timescaledb_inventory.yml
---
all:
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: "{{ lookup('env', 'HOME') }}/retrieved_key.pem"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  children:
    timescaledb_servers:
      hosts:
        $STANDBY_PUBLIC_IP: {}
        $TIMESCALEDB_PRIVATE_IP: {}
EOF

echo "Playbooks created. Proceed with running Ansible playbooks as needed."

# Generate the Ansible playbook
cat <<EOF > $HOME/check_ssh.yml
---
- name: Check SSH connectivity within VPC for TimescaleDB to ClusterControl
  hosts: timescaledb_servers
  vars:
    clustercontrol_private_ip: "172.31.32.75"
  tasks:
    - name: Check SSH connectivity to ClusterControl as barman (internal)
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no barman@{{ clustercontrol_private_ip }} echo 'SSH to ClusterControl as barman successful'
      when: "'172.31.' in inventory_hostname"
      delegate_to: "{{ inventory_hostname }}"
      become: true
      become_user: postgres
      ignore_errors: true
      register: ssh_check_internal
    - name: Show SSH check result (internal)
      debug:
        var: ssh_check_internal.stdout_lines
      when: "'172.31.' in inventory_hostname"

    - name: Inform about external SSH check skip
      debug:
        msg: "Skipping SSH check for {{ inventory_hostname }} to ClusterControl internal IP, as it's expected to be inaccessible from external networks."
      when: "'172.31.' not in inventory_hostname"


- name: Check SSH connectivity over Internet for Standby to ClusterControl
  hosts: timescaledb_servers
  vars:
    clustercontrol_public_ip: "43.207.147.235" # Assuming this is the variable's correct value
  tasks:
    - name: Check SSH connectivity to ClusterControl as barman (external)
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no barman@{{ clustercontrol_public_ip }} echo 'SSH to ClusterControl as barman successful'
      when: inventory_hostname == "timescaledb.mywire.org"
      delegate_to: "{{ inventory_hostname }}"
      become: true
      become_user: postgres
      ignore_errors: true
      register: ssh_check_external
    - name: Show SSH check result (external)
      debug:
        var: ssh_check_external.stdout_lines

- name: Check SSH connectivity from user barman in ClusterControl to TimescaleDB servers as postgres users
  hosts: localhost
  vars:
    timescaledb_servers:
      - $TIMESCALEDB_PRIVATE_IP
      - $STANDBY_PUBLIC_IP
  tasks:
    - name: Check SSH connectivity to TimescaleDB as postgres
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no postgres@{{ item }} echo 'SSH to TimescaleDB as postgres successful'
      loop: "{{ timescaledb_servers }}"
      become: true
      become_user: barman
      ignore_errors: true
      register: ssh_check
    - name: Show SSH check result
      debug:
        msg: "{{ item.item }}: {{ item.stdout }}"
      loop: "{{ ssh_check.results }}"
EOF

# Create an Ansible configuration file with a fixed temporary directory
cat <<EOF > $HOME/ansible_cc.cfg
[defaults]
remote_tmp = /tmp/ansible/tmp
EOF

# Export ANSIBLE_CONFIG to use the newly created configuration file
export ANSIBLE_CONFIG=$HOME/ansible_cc.cfg

echo "Ansible configuration file created at: $HOME/ansible_cc.cfg"
# Ensure the temporary directory exists on localhost
mkdir -p /tmp/ansible/tmp
chmod 1777 /tmp/ansible/tmp

# Playbook to ensure the temporary directory exists on remote hosts
cat <<EOF > $HOME/ensure_remote_tmp.yml
---
- name: Ensure Ansible temporary directory exists on all hosts
  hosts: all
  become: yes
  tasks:
    - name: Create Ansible temporary directory
      file:
        path: "/tmp/ansible/tmp"
        state: directory
        mode: '1777'
EOF

# Execute the playbook
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ensure_remote_tmp.yml
# Execute playbooks
#ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/install_acl.yml
#ansible-playbook $HOME/configure_barman_on_cc.yml
#ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/modify_sudoers.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_ssh_from_cc.yml
ansible-playbook -vv -i $HOME/timescaledb_inventory.yml $HOME/check_ssh.yml
