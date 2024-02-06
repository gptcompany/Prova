#!/bin/bash

# Check for the correct number of arguments
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 TIMESCALEDB_IP STANDBY_IP SSH_USER_POSTGRES CLUSTERCONTROL_IP ECS_INSTANCE_IP"
    exit 1
fi

# Assign arguments to variables
TIMESCALEDB_IP=$1
STANDBY_IP=$2
SSH_USER_POSTGRES=$3
CLUSTERCONTROL_IP=$4
ECS_INSTANCE_IP=$5
AWS_SECRET_ID="ultimaec2key"

# Echo variables for debugging
echo "TIMESCALEDB_IP: $TIMESCALEDB_IP"
echo "STANDBY_IP: $STANDBY_IP"
echo "SSH_USER_POSTGRES: $SSH_USER_POSTGRES"
echo "CLUSTERCONTROL_IP: $CLUSTERCONTROL_IP"
echo "ECS_INSTANCE_IP: $ECS_INSTANCE_IP"

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

# Create the inventory file dynamically
mkdir -p $HOME/statarb/scripts
cat <<EOF > $HOME/statarb/scripts/hosts.ini
[timescaledb_servers]
timescaledb_primary ansible_host=$TIMESCALEDB_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_home=/var/lib/postgresql custom_user=$SSH_USER_POSTGRES
timescaledb_standby ansible_host=$STANDBY_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_home=/var/lib/postgresql custom_user=$SSH_USER_POSTGRES

[ecs]
ecs_instance ansible_host=$ECS_INSTANCE_IP ansible_user=ec2-user ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_user=postgres custom_home=/var/lib/postgresql

[clustercontrol]
clustercontrol_instance ansible_host=$CLUSTERCONTROL_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_user=barman custom_home=/home/barman
EOF

cat <<EOF > $HOME/statarb/scripts/vpc_hosts.ini
[timescaledb_servers_vpc]
timescaledb_primary ansible_host=$TIMESCALEDB_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_home=/var/lib/postgresql custom_user=$SSH_USER_POSTGRES
timescaledb_standby ansible_host=$STANDBY_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_home=/var/lib/postgresql custom_user=$SSH_USER_POSTGRES

[ecs_vpc]
ecs_instance ansible_host=$ECS_INSTANCE_IP ansible_user=ec2-user ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_user=postgres custom_home=/var/lib/postgresql

[clustercontrol_vpc]
clustercontrol_instance ansible_host=$CLUSTERCONTROL_IP ansible_user=ubuntu ansible_ssh_private_key_file=$HOME/retrieved_key.pem custom_user=barman custom_home=/home/barman
EOF
# Echo the path of hosts.ini for debugging
echo "Inventory file created at: $HOME/statarb/scripts/hosts.ini"

# Create an Ansible configuration file dynamically
cat <<EOF > $HOME/statarb/scripts/ansible_cc.cfg
[defaults]
remote_tmp = /tmp/.ansible/\${USER}/tmp
inventory = $HOME/statarb/scripts/hosts.ini
EOF

# Adjust playbook execution to use the new ansible.cfg
export ANSIBLE_CONFIG=$HOME/statarb/scripts/ansible_cc.cfg

echo "Ansible configuration file created at: $HOME/statarb/scripts/ansible_cc.cfg"

# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/statarb/scripts/configure_timescaledb.yml
---
- name: Configure TimescaleDB Servers
  hosts: timescaledb_servers
  become: yes  # This elevates privilege for the entire playbook; adjust as necessary for your environment

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

    - name: Ensure TimescaleDB can accept connections
      ansible.builtin.lineinfile:
        path: "{{ pg_hba_dir }}/pg_hba.conf"
        line: "host all all {{ ansible_default_ipv4.address }}/32 trust"
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
      become: yes  # Privilege escalation may be required to restart the service
EOF


# Echo the path of configure_timescaledb.yml for debugging
echo "Playbook file created at: $HOME/statarb/scripts/configure_timescaledb.yml"

# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/statarb/scripts/configure_sshd.yml
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
      - { regex: "^Subsystem sftp", line: "Subsystem       sftp    /usr/lib/openssh/sftp-server" }
      - { regex: "^KbdInteractiveAuthentication ", line: "KbdInteractiveAuthentication no" }
      - { regex: "^UsePAM ", line: "UsePAM yes" }
      - { regex: "^AuthorizedKeysFile ", line: "AuthorizedKeysFile      .ssh/authorized_keys .ssh/authorized_keys2" }
      - { regex: "^AllowAgentForwarding ", line: "AllowAgentForwarding yes" }


  tasks:
    - name: Backup SSHD configuration
        ansible.builtin.copy:
          src: /etc/ssh/sshd_config
          dest: /etc/ssh/sshd_config.bak
        register: backup_result
        ignore_errors: yes  # Ignore errors if backup already exists

    - name: Ensure SSHD settings are configured
      ansible.builtin.lineinfile:
        path: "{{ sshd_config_path }}"
        regexp: "{{ item.regex }}"
        line: "{{ item.line }}"
        state: present
      loop: "{{ sshd_settings }}"
      notify: reload sshd

  handlers:
    - name: reload sshd
      ansible.builtin.service:
        name: sshd
        state: reloaded

    - name: Restore SSHD configuration (on failure)
      ansible.builtin.copy:
        src: /etc/ssh/sshd_config.bak
        dest: /etc/ssh/sshd_config
      when: backup_result.failed
EOF

##################################################TODO:
# Implement a fail-safe mechanism within the Ansible playbook.

#     You can use Ansible's built-in conditional statements to check if the SSH configuration changes are successful.
#     If the changes are not successful, you can use Ansible to revert the SSHD configuration to its previous state.

# Echo the path of configure_sshd.yml for debugging
echo "Playbook file created at: $HOME/statarb/scripts/configure_sshd.yml"

# Create the Ansible playbook file dynamically
cat <<EOF > $HOME/statarb/scripts/configure_ssh_all.yml
---
- name: Setup SSH Keys and Access
  hosts: all
  gather_facts: no
  tasks:
    - name: Check if SSH key exists for custom user
      ansible.builtin.stat:
        path: "{{ hostvars[inventory_hostname].custom_home }}/.ssh/id_rsa.pub"
      register: ssh_key_check
      become: yes
      become_user: "{{ hostvars[inventory_hostname].custom_user }}"

    - name: Generate SSH key for custom user
      ansible.builtin.user:
        name: "{{ hostvars[inventory_hostname].custom_user }}"
        generate_ssh_key: yes
        ssh_key_bits: 2048
        home: "{{ hostvars[inventory_hostname].custom_home }}"
      when: ssh_key_check.stat.exists == false
      become: yes

    - name: Fetch the public key from custom user
      ansible.builtin.fetch:
        src: "{{ hostvars[inventory_hostname].custom_home }}/.ssh/id_rsa.pub"
        dest: "./keys/{{ inventory_hostname }}_ssh_key.pub"
        flat: yes
      become: yes
      become_user: "{{ hostvars[inventory_hostname].custom_user }}"
      when: ssh_key_check.stat.exists == true or ansible_check_mode

    - name: Ensure .ssh directory exists for custom user
      ansible.builtin.file:
        path: "{{ hostvars[inventory_hostname].custom_home }}/.ssh"
        state: directory
        mode: '0700'
        owner: "{{ hostvars[inventory_hostname].custom_user }}"
        group: "{{ hostvars[inventory_hostname].custom_user }}"
      become: yes

    - name: Set up SSH authorized_keys for the custom user
      ansible.builtin.authorized_key:
        user: "{{ item.custom_user }}"
        key: "{{ lookup('file', './keys/' + item.host + '_ssh_key.pub') }}"
        manage_dir: no
      loop: "{{ query('inventory_hostnames', 'all') }}"
      loop_control:
        loop_var: item
      when: item != inventory_hostname
      become: yes
      vars:
        item:
          host: "{{ inventory_hostname }}"
          custom_user: "{{ hostvars[inventory_hostname].custom_user }}"

EOF
###########################################TODO:

# user barman from CLUSTERCONTROL_IP to ssh into postgres user in STANDBY_PUBLIC_IP, TIMESCALEDB_PRIVATE_IP ????????????

# user postgres from STANDBY_IP to ssh into barman user in CLUSTERCONTROL_IP
# user postgres from TIMESCALEDB_IP to ssh into barman user in CLUSTERCONTROL_IP
# user ubuntu from TIMESCALEDB_IP to ssh into ubuntu user in STANDBY_IP, CLUSTERCONTROL_IP
# user ubuntu from STANDBY_IP to ssh into ubuntu user in TIMESCALEDB_IP, CLUSTERCONTROL_IP

# user ubuntu from CLUSTERCONTROL_IP to ssh into ubuntu in TIMESCALEDB_PRIVATE_IP, STANDBY_PUBLIC_IP      OK********************

# user ec2-user from ECS_INSTANCE_IP to ssh into ubuntu in TIMESCALEDB_IP, CLUSTERCONTROL_IP, STANDBY_IP
# users ubuntu from TIMESCALEDB_IP, CLUSTERCONTROL_IP, STANDBY_IP to ssh into ec2-user ECS_INSTANCE_IP

# STANDBY_IP
# TIMESCALEDB_IP
# CLUSTERCONTROL_IP
# ECS_INSTANCE_IP

# Echo the path of configure_sshd.yml for debugging
echo "Playbook file created at: $HOME/statarb/scripts/configure_ssh_all.yml"


# Create keys directory if it doesn't exist
KEYS_DIR="$HOME/statarb/scripts/keys"
if [ ! -d "$KEYS_DIR" ]; then
    echo "Creating $KEYS_DIR directory for SSH keys..."
    mkdir -p "$KEYS_DIR"
fi
# Backup sshd_config before making changes
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%F-%H-%M-%S)"
if [ -f "$SSHD_CONFIG" ]; then
    echo "Backing up SSHD configuration to $SSHD_CONFIG_BACKUP"
    sudo cp $SSHD_CONFIG $SSHD_CONFIG_BACKUP
else
    echo "SSHD configuration file not found."
    exit 1
fi
# Set LogLevel to DEBUG3 for detailed SSHD logs
sudo sed -i 's/^#LogLevel INFO/LogLevel DEBUG3/' $SSHD_CONFIG
# Ensure SSHD is reloaded to apply temporary log level change
sudo systemctl reload sshd

# Proceed to execute Ansible playbooks
echo "Executing Ansible playbooks..."
# Execute the Ansible playbook for sshd
ansible-playbook -vv -i $HOME/statarb/scripts/hosts.ini $HOME/statarb/scripts/configure_sshd.yml -e 'ansible_ssh_common_args="-o StrictHostKeyChecking=no"'
# Implement a fail-safe mechanism: Wait for user confirmation to keep changes
echo "Please confirm SSH configuration works by typing 'confirm':"
read -t 300 confirmation  # Wait for 5 minutes
if [ "$confirmation" != "confirm" ]; then
    echo "Confirmation not received, reverting SSHD configuration..."
    sudo mv $SSHD_CONFIG_BACKUP $SSHD_CONFIG
    sudo systemctl reload sshd
    echo "SSHD configuration reverted."
else
    echo "Confirmation received, changes kept."
    # Optionally revert LogLevel to INFO after confirmation
    sudo sed -i 's/^LogLevel DEBUG3/#LogLevel INFO/' $SSHD_CONFIG
    sudo systemctl reload sshd
fi

# Execute the Ansible playbook for ssh
ansible-playbook -vv -i $HOME/statarb/scripts/hosts.ini $HOME/statarb/scripts/configure_ssh_all.yml -e 'ansible_ssh_common_args="-o StrictHostKeyChecking=no"'


# Execute the Ansible playbook for pg_hba
ansible-playbook -vv -i $HOME/statarb/scripts/hosts.ini $HOME/statarb/scripts/configure_timescaledb.yml


