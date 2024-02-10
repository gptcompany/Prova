
#!/bin/bash
# Check for the correct number of arguments
# if [ "$#" -ne 1 ]; then
#     echo "Usage: $0 TIMESCALEDB_PRIVATE_IP"
#     exit 1
# fi

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
# Check if Ansible is installed, install if not
if ! command -v ansible > /dev/null; then
    echo "Ansible not found. Installing Ansible..."
    sudo apt-get update
    sudo apt-get install -y ansible
else
    echo "Ansible is already installed."
fi
# Fetch secret from AWS Systems Manager (SSM) Parameter Store
if command -v aws > /dev/null; then
    echo "Fetching SSH key from AWS Systems Manager Parameter Store..."
    aws ssm get-parameter --name $AWS_SECRET_ID --with-decryption --query 'Parameter.Value' --output text > $HOME/retrieved_key.pem
    chmod 600 $HOME/retrieved_key.pem
else
    echo "AWS CLI not found. Please install AWS CLI and configure it."
    exit 1
fi

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
  hosts: timescaledb_servers
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

EOF

# Create the playbook to modify sudoers based on the users on the host
cat <<EOF > $HOME/modify_sudoers.yml
---
- name: Update sudoers for specific users based on their roles
  hosts: all
  gather_facts: no
  become: yes
  tasks:
    - name: Ensure ubuntu user can run all commands without a password on applicable hosts
      lineinfile:
        path: /etc/sudoers.d/ubuntu
        line: 'ubuntu ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
      when: "'ubuntu' in ansible_user or 'clustercontrol' in group_names or 'timescaledb_servers' in group_names"

    - name: Ensure postgres user has necessary sudo privileges on TimescaleDB servers
      lineinfile:
        path: /etc/sudoers.d/postgres
        line: 'postgres ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
      when: "'timescaledb_servers' in group_names"

    - name: Ensure barman user has necessary sudo privileges on ClusterControl servers
      lineinfile:
        path: /etc/sudoers.d/barman
        line: 'barman ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
      when: "'clustercontrol' in group_names"

    - name: Ensure ec2-user can run all commands without a password on ECS instances
      lineinfile:
        path: /etc/sudoers.d/ec2-user
        line: 'ec2-user ALL=(ALL) NOPASSWD: ALL'
        create: yes
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
      when: "'ecs' in group_names"

EOF


# Create the playbook for SSH setup
cat <<EOF > $HOME/configure_ssh_from_cc.yml
---
- name: Setup SSH Key for ubuntu User Locally
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
      ansible.builtin.slurp:
        src: "{{ lookup('env','HOME') }}/.ssh/id_rsa.pub"
      register: ubuntu_ssh_pub_key
      delegate_to: localhost

    - name: Ensure ubuntu user can SSH into each server without a password
      ansible.builtin.authorized_key:
        user: "{{ ansible_user }}"
        state: present
        key: "{{ ubuntu_ssh_pub_key.content | b64decode }}"


- name: Ensure SSH public key is readable by all
  hosts: localhost
  gather_facts: no
  become: yes
  become_user: root
  tasks:
    - name: Set file permissions for id_rsa.pub
      ansible.builtin.file:
        path: /var/lib/barman/.ssh/id_rsa.pub
        mode: '0644'

    - name: Set ACL for ubuntu user on specific directories
      ansible.builtin.command:
        cmd: "setfacl -m u:ubuntu:rx {{ item }}"
      loop:
        - /var/lib/barman
        - /var/lib/barman/.ssh
        - /var/lib/barman/.ssh/id_rsa.pub

    - name: Verify /var/lib/barman/.ssh/id_rsa.pub
      ansible.builtin.command:
        cmd: "getfacl /var/lib/barman/.ssh/id_rsa.pub"
      register: acl_check

    - name: Show ACL settings for /var/lib/barman/.ssh/id_rsa.pub
      ansible.builtin.debug:
        msg: "{{ acl_check.stdout }}"

- name: Slurp Barman's SSH public key and decode
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Slurp Barman's SSH public key 
      ansible.builtin.slurp:
        src: /var/lib/barman/.ssh/id_rsa.pub
      register: barman_ssh_key_slurped

    - name: Decode and store Barman's SSH public key
      set_fact:
        barman_ssh_key: "{{ barman_ssh_key_slurped['content'] | b64decode }}"

- name: Setup user postgres on timescaledb servers
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

- name: Ensure SSH public key is readable by all
  hosts: timescaledb_servers
  gather_facts: no
  become: yes
  become_user: root
  tasks:
    - name: Set file permissions for id_rsa.pub
      ansible.builtin.file:
        path: /var/lib/postgresql/.ssh/id_rsa.pub
        mode: '0644'

    - name: Set ACL for ubuntu user on specific directories
      ansible.builtin.command:
        cmd: "setfacl -m u:ubuntu:rx {{ item }}"
      loop:
        - /var/lib/postgresql
        - /var/lib/postgresql/.ssh
        - /var/lib/postgresql/.ssh/id_rsa.pub

    - name: Verify /var/lib/postgresql/.ssh/id_rsa.pub
      ansible.builtin.command:
        cmd: "getfacl /var/lib/postgresql/.ssh/id_rsa.pub"
      register: acl_check

    - name: Show ACL settings for /var/lib/postgresql/.ssh/id_rsa.pub
      ansible.builtin.debug:
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
# Generate the Ansible plybook for ecs
cat <<EOF > $HOME/ecs_instance.yml
---
- name: Ensure SSH Key Pair Exists for ec2-user
  hosts: ecs
  become: yes  # Ensure Ansible uses sudo to execute commands
  become_user: ec2-user  # Switch to ec2-user for these operations
  tasks:
    - name: Check if SSH public key exists
      stat:
        path: "/home/ec2-user/.ssh/id_rsa.pub"
      register: ssh_key_pub_ecs

    - name: Generate SSH key pair for ec2-user
      command: ssh-keygen -t rsa -b 2048 -f /home/ec2-user/.ssh/id_rsa -q -N ""
      when: ssh_key_pub_ecs.stat.exists == false
      args:
        creates: "/home/ec2-user/.ssh/id_rsa.pub"

    - name: Fetch the public SSH key of ec2-user
      slurp:
        src: "/home/ec2-user/.ssh/id_rsa.pub"
      register: ec2_user_ssh_pub_key
      delegate_to: "{{ inventory_hostname }}"
    ##########################################USE FOR DEBUG#########################################
    # - name: Print the public key
    #   debug:
    #     msg: "{{ ec2_user_ssh_pub_key.content | b64decode }}"

- name: Setup SSH Access for ubuntu User on ECS Servers
  hosts: ecs
  gather_facts: no
  tasks:
    - name: Fetch the public key of ubuntu user
      ansible.builtin.slurp:
        src: "{{ lookup('env','HOME') }}/.ssh/id_rsa.pub"
      register: ubuntu_ssh_pub_key
      delegate_to: localhost

    - name: Ensure ubuntu user can SSH into ECS servers without a password
      ansible.builtin.authorized_key:
        user: ec2-user
        state: present
        key: "{{ ubuntu_ssh_pub_key.content | b64decode }}"
      when: "'ecs' in group_names"

    - name: Authorize ECS's public key on localhost for ubuntu user
      ansible.builtin.lineinfile:
        path: "{{ lookup('env','HOME') }}/.ssh/authorized_keys"
        line: "{{ ec2_user_ssh_pub_key.content | b64decode }}"
        state: present
      delegate_to: localhost
      when: ec2_user_ssh_pub_key.content is defined
      become: false  # Assuming the Ansible user can write to their own .ssh directory without sudo
EOF

# Generate the Ansible inventory
cat <<EOF > $HOME/timescaledb_inventory.yml
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


    
        

echo "Playbooks created. Proceed with running Ansible playbooks as needed."

# Generate the Ansible playbook
cat <<EOF > $HOME/check_ssh.yml
---
- name: Check SSH connectivity within VPC for Timescaledb server postgres user to ClusterControl barman user
  hosts: timescaledb_servers
  vars:
    clustercontrol_private_ip: "{{ hostvars['clustercontrol_private_server'].ansible_host }}"
  tasks:
    - name: Check SSH connectivity from timescaledb_servers postgres users to ClusterControl as barman user (internal) IMPORTANT**
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no barman@{{ clustercontrol_private_ip }} echo 'SSH to ClusterControl as barman successful'
      when: >
        'internal' in role

      delegate_to: "{{ inventory_hostname }}"
      become: true
      become_user: postgres
      ignore_errors: true
      register: ssh_check_internal

    - name: Inform about external SSH check skip
      debug:
        msg: "Skipping SSH check for {{ inventory_hostname }} to ClusterControl internal IP, as it's expected to be inaccessible from external networks."
      when: "'external' in role"
    
    - name: Show SSH check result (only internal)
      debug:
        var: ssh_check_internal.stdout_lines
      when: ssh_check_internal is defined and ssh_check_internal.stdout_lines is defined

- name: Check SSH connectivity over Internet for Standby server postgres user to ClusterControl barman user (external) IMPORTANT**
  hosts: standby_server
  vars:
    clustercontrol_public_ip: "{{ hostvars['clustercontrol_public_server'].ansible_host }}"
  tasks:
    - name: Check SSH connectivity to ClusterControl as barman (external)
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no barman@{{ clustercontrol_public_ip }} echo 'SSH to ClusterControl as barman successful'
      delegate_to: "{{ inventory_hostname }}"
      become: true
      become_user: postgres
      ignore_errors: true
      register: ssh_check_external

    - name: Show SSH check result (only external)
      debug:
        var: ssh_check_external.stdout_lines
      when: ssh_check_external is defined and ssh_check_external.stdout_lines is defined

- name: Check SSH connectivity from user barman in ClusterControl to TimescaleDB servers as postgres users IMPORTANT**
  hosts: localhost
  vars:
    timescaledb_servers: "{{ groups['timescaledb_servers'] }}"
  tasks:
    - name: Check SSH connectivity from barman user on ClusterControl to TimescaleDB servers as postgres user IMPORTANT**
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no postgres@{{ hostvars[item].ansible_host }} echo 'SSH to TimescaleDB as postgres successful'
      loop: "{{ timescaledb_servers }}"
      become: true
      become_user: barman
      ignore_errors: true
      register: ssh_check
    - name: Show SSH check result
      debug:
        msg: "{{ item.item }}: {{ item.stdout }}"
      loop: "{{ ssh_check.results }}"
      when: ssh_check.results is defined

- name: Check SSH connectivity from user ubuntu to ec2-user in ecs hosts
  hosts: ecs
  gather_facts: no
  tasks:
    - name: Check SSH connectivity to ECS as ec2-user
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no ec2-user@{{ ansible_host }} echo 'SSH to ECS as ec2-user successful'
      delegate_to: localhost
      ignore_errors: true
      register: ssh_check_ecs
    ################################USE FOR DEBUG#############################################
    # - name: Show SSH check result to ECS
    #   debug:
    #     msg: "SSH connectivity to {{ inventory_hostname }} as ec2-user: {{ ssh_check_ecs.stdout }}"
    #   when: ssh_check_ecs is defined and ssh_check_ecs.stdout is defined

- name: Check SSH connectivity from ec2-user in ecs hosts to user ubuntu on localhost
  hosts: ecs
  gather_facts: no
  tasks:
    - name: Check SSH connectivity to ClusterControl private server as ubuntu
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@{{ hostvars['clustercontrol_private_server'].ansible_host }} echo 'SSH to ClusterControl private server as ubuntu successful'
      delegate_to: "{{ inventory_hostname }}"
      ignore_errors: true

    - name: Check SSH connectivity to ClusterControl public server as ubuntu
      command: ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@{{ hostvars['clustercontrol_public_server'].ansible_host }} echo 'SSH to ClusterControl public server as ubuntu successful'
      delegate_to: "{{ inventory_hostname }}"
      ignore_errors: true

    ################################USE FOR DEBUG#############################################
    # - name: Show SSH check result to localhost
    #   debug:
    #     msg: "SSH connectivity from {{ inventory_hostname }} as ec2-user to localhost: {{ ssh_check_localhost.stdout }}"
    #   when: ssh_check_localhost is defined and ssh_check_localhost.stdout is defined

EOF


cat <<EOF > $HOME/install_packages.yml
---
- name: Install required packages and software on localhost
  hosts: localhost
  connection: local
  become: yes
  tasks:
    - name: Update and upgrade apt packages
      ansible.builtin.apt:
        update_cache: yes
        upgrade: 'yes'

    - name: Install necessary packages
      ansible.builtin.apt:
        name:
          - build-essential
          - libpq-dev
          - python3-dev
          - curl
          - wget
          - rsync
          - software-properties-common
          - postgresql
          - postgresql-contrib
        state: present

    - name: Check if Node.js is installed
      command: node -v
      register: node_version
      ignore_errors: yes

    - name: Install Node.js if not present
      block:
        - name: Download Node.js setup script
          ansible.builtin.get_url:
            url: https://deb.nodesource.com/setup_20.x
            dest: /tmp/setup_node.sh
            mode: '0755'
        - name: Execute Node.js setup script
          ansible.builtin.shell: bash /tmp/setup_node.sh
        - name: Install Node.js
          ansible.builtin.apt:
            name: nodejs
            state: latest
      when: node_version.rc != 0

    - name: Check if n8n is installed
      command: n8n --version
      register: n8n_version_result
      ignore_errors: yes

    - name: Install n8n if not already installed
      block:
        - name: Install n8n globally using npm
          ansible.builtin.shell: sudo npm install n8n -g
      when: n8n_version_result.rc != 0

    - name: Check if ClusterControl is installed
      command: cmon --version
      register: cmon_version_result
      ignore_errors: yes

    - name: Download and install ClusterControl if not present
      ansible.builtin.shell: |
        curl -L https://severalnines.com/downloads/cmon/install-cc -o install-cc
        chmod +x install-cc
        ./install-cc
      when: cmon_version_result.rc != 0

EOF
# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/configure_sshd.yml
---
- name: Configure SSHD Settings
  hosts: all
  become: yes
  vars:
    sshd_config_path: /etc/ssh/sshd_config
    sshd_settings:
      - { regex: "^Port ", line: "Port 22" }
      - { regex: "^ListenAddress ", line: "ListenAddress 0.0.0.0" }
      - { regex: "^PubkeyAuthentication ", line: "PubkeyAuthentication yes" }
      - { regex: "^PasswordAuthentication ", line: "PasswordAuthentication no" }
      - { regex: "^ClientAliveInterval ", line: "ClientAliveInterval 60" }
      - { regex: "^ClientAliveCountMax ", line: "ClientAliveCountMax 120" }
      - { regex: "^X11Forwarding ", line: "X11Forwarding yes" }
      - { regex: "^PrintMotd ", line: "PrintMotd no" }
      - { regex: "^AcceptEnv ", line: "AcceptEnv LANG LC_*" }
      - { regex: "^KbdInteractiveAuthentication ", line: "KbdInteractiveAuthentication no" }
      - { regex: "^UsePAM ", line: "UsePAM yes" }
      - { regex: "^AuthorizedKeysFile ", line: "AuthorizedKeysFile      .ssh/authorized_keys .ssh/authorized_keys2" }
      - { regex: "^AllowAgentForwarding ", line: "AllowAgentForwarding yes" }
      # Exclude the Subsystem sftp line to avoid duplication

  tasks:

    - name: Backup SSHD configuration
      ansible.builtin.copy:
        src: "{{ sshd_config_path }}"
        dest: "{{ sshd_config_path }}.bak"
      register: backup_result

    - name: Ensure SSHD settings are configured
      ansible.builtin.lineinfile:
        path: "{{ sshd_config_path }}"
        regexp: "{{ item.regex }}"
        line: "{{ item.line }}"
        state: present
      loop: "{{ sshd_settings }}"
      notify: check sshd config

    - name: Remove duplicate Subsystem sftp entries
      ansible.builtin.lineinfile:
        path: "{{ sshd_config_path }}"
        regexp: '^(Subsystem\s+sftp\s+).*'
        state: absent
        backrefs: yes
      register: sftp_removal

    - name: Ensure correct Subsystem sftp configuration
      ansible.builtin.lineinfile:
        path: "{{ sshd_config_path }}"
        line: "Subsystem sftp /usr/lib/openssh/sftp-server"
        state: present
      when: sftp_removal.changed

    - name: Test SSHD configuration
      ansible.builtin.command:
        cmd: sshd -t
      register: sshd_test
      failed_when: sshd_test.rc != 0
      ignore_errors: yes

    - name: Restore SSHD configuration if sshd test fails
      ansible.builtin.copy:
        src: "{{ sshd_config_path }}.bak"
        dest: "{{ sshd_config_path }}"
      when: sshd_test.failed
      # This needs to be a direct task, not a handler

  handlers:
    - name: reload sshd
      ansible.builtin.service:
        name: sshd
        state: reloaded
      when: sshd_test.rc == 0 and not sshd_test.failed
EOF

# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/configure_pgpass.yml
---
- name: Update .pgpass with TimescaleDB password
  hosts: timescaledb_servers
  gather_facts: yes
  become: yes
  become_user: postgres  # Global escalation to postgres user
  tasks:
    - name: Get information about the postgres user
      ansible.builtin.getent:
        database: passwd
        key: postgres
      register: postgres_user_info

    - name: Get localhost IP address
      ansible.builtin.shell: "hostname -I | awk '{print $1}'"
      register: localhost_ip
      
    - name: Ensure /var/lib/postgresql directory is writable by postgres
      ansible.builtin.file:
        path: /var/lib/postgresql
        owner: postgres
        group: postgres
        mode: '0755'
      become: yes
      become_user: root

    - name: Ensure .pgpass file exists for setting permissions
      ansible.builtin.file:
        path: "{{ postgres_user_info.ansible_facts.getent_passwd['postgres'][4] }}/.pgpass"
        state: touch
        owner: postgres
        group: postgres
        mode: '0600'
      become: yes
      become_user: root

    - name: Set correct permissions on .pgpass
      ansible.builtin.file:
        path: "{{ postgres_user_info.ansible_facts.getent_passwd['postgres'][4] }}/.pgpass"
        owner: postgres
        group: postgres
        mode: '0600'
      become: yes
      become_user: root

    - name: Set ACL for postgres user on .pgpass (optional, if needed)
      ansible.builtin.acl:
        path: "{{ postgres_user_info.ansible_facts.getent_passwd['postgres'][4] }}/.pgpass"
        entity: postgres
        etype: user
        permissions: rwx
        state: present
      become: yes
      become_user: root
      ignore_errors: yes # Use ignore_errors if ACLs are not supported on your filesystem

    - name: Ensure .pgpass contains the required line
      ansible.builtin.lineinfile:
        path: "{{ postgres_user_info.ansible_facts.getent_passwd['postgres'][4] }}/.pgpass"
        line: "{{ localhost_ip.stdout }}:5432:*:*:{{ timescaledb_password }}"
        create: yes
        state: present
        mode: '0600'
      become: yes
      become_user: postgres
EOF

echo "Playbook file created at: $HOME/configure_pgpass.yml"



# Create an Ansible configuration file with a fixed temporary directory
cat <<EOF > $HOME/ansible_cc.cfg
[defaults]
remote_tmp = /var/tmp/ansible-tmp
# ansible_python_interpreter: /usr/lib/python3
EOF
echo "Ansible configuration file created at: $HOME/ansible_cc.cfg"
# Export ANSIBLE_CONFIG to use the newly created configuration file
export ANSIBLE_CONFIG=$HOME/ansible_cc.cfg
echo "Using Ansible configuration file at: $ANSIBLE_CONFIG"
# Ensure the temporary directory exists on localhost
mkdir -p /var/tmp/ansible-tmp
chmod 777 /var/tmp/ansible-tmp

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

sudo setenforce 0
sudo systemctl stop apparmor
sudo systemctl disable apparmor

sudo usermod -aG ubuntu barman
echo "barman sudo priv added!"
# Execute playbooks
sudo apt install ansible -y
ansible-galaxy collection install community.aws --force
ansible-galaxy collection install amazon.aws --force
ansible-galaxy collection install ansible.posix --force
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/install_acl.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ensure_remote_tmp.yml
ansible-playbook $HOME/configure_barman_on_cc.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/modify_sudoers.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_ssh_from_cc.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/ecs_instance.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_sshd.yml
ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/check_ssh.yml
ansible-playbook $HOME/install_packages.yml  #on localhost


ansible-playbook -i $HOME/timescaledb_inventory.yml $HOME/configure_pgpass.yml -e "timescaledb_password=${TIMESCALEDBPASSWORD}"


