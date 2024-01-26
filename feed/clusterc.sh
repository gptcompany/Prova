sudo apt update
sudo apt upgrade
sudo apt install curl wget rsync
sudo apt install -y software-properties-common
curl -L https://severalnines.com/downloads/cmon/install-cc -o install-cc
chmod +x install-cc
sudo ./install-cc


/var/lib/pgsql/data
/var/log/cmon.log
/var/lib/pgsql/data/log/postgresql.log
sudo systemctl restart sshd
sudo service ssh restart

ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
ssh-copy-id 192.168.0.10
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

sudo setenforce 0
sudo systemctl stop apparmor
sudo systemctl disable apparmor
