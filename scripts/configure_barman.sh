
#!/bin/bash
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
      barman_home = /home/barman
      log_file = /home/barman/barman.log
      log_level = INFO
      compression = pigz
      parallel_jobs = 3

      [timescaledb]
      description = "Timescaledb Server"
      ssh_command = ssh postgres@172.31.35.73
      conninfo = host=172.31.35.73 user=postgres password=Timescaledb2023

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

ansible-playbook -v $HOME/configure_barman.yml  #on localhost
