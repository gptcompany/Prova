#!/bin/bash

# Install Barman and Barman-cli if not already installed
sudo apt-get update
sudo apt-get install -y barman barman-cli

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
      conninfo = host=172.31.35.73 user=postgres password=Timescaledb2023
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
      become: no  # Run verification as the barman user without sudo
      ignore_errors: yes

    - name: Report Barman check failure
      ansible.builtin.debug:
        msg: "Barman configuration check failed. Please review the configuration."
      when: barman_check is failed
EOF

# Set ACL for the barman user on /etc/barman.conf
# This ensures barman has the necessary permissions
sudo setfacl -m u:barman:rw- /etc/barman.conf

# Run the Ansible playbook
sudo ansible-playbook -v $HOME/configure_barman.yml  #on localhost
