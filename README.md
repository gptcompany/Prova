# startarb
When changing EC2 IP please check the github action ec2 instance ip or name if correct!

Run install_packages.sh for installing packages without ansible
Run ultimaec2_backup_to_s3.sh and timesacledbinstance_backup_to_s3.sh and with a CRON JOB!

Start by running the script install_cc_instance.sh on the cluster control instance, this will set all the connection ssh and will setup barman and clustercontrol with ansible support!
**************Before run the script install_cc_instance.sh check if all the variables in configure_cc_ansible.sh are correctly set!**************