
##INSTALL POSTGRES 15 latest
#IF amazon linux 2023
sudo dnf install postgresql15.x86_64 postgresql15-server -y
psql -V
sudo postgresql-setup --initdb
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo tee /etc/yum.repos.d/timescaledb.repo <<EOF                                                                                                                1 ✘  ec2-user@ip-172-31-39-186  23:07:22  ▓▒░
[timescaledb]
name=timescaledb
baseurl=https://packagecloud.io/timescale/timescaledb/el/7/\$basearch
repo_gpgcheck=0
enabled=1
gpgcheck=0
gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
sslverify=0
metadata_expire=300
EOF
sudo dnf install timescaledb-2-postgresql-15 -y
sudo dnf groupinstall "Development Tools" -y
sudo dnf install postgresql-devel -y
sudo yum remove postgresql15 postgresql15-private-libs postgresql15-server -y
wget https://ftp.postgresql.org/pub/source/v15.4/postgresql-15.4.tar.gz
tar -xzf postgresql-15.4.tar.gz
sudo rm -r postgresql-15.4.tar.gz
cd ~/postgresql-15.4
sudo ./configure --with-openssl
sudo make
sudo make install
sudo ldconfig
# from the location of postgres.h we can implement all other paths correctly
sudo find / -name 'postgres.h'
cd
sudo sh -c 'echo "export PATH=$PATH:/usr/local/pgsql/bin" >> ~/.bashrc'
sudo sh -c 'echo "export PATH=$PATH:/usr/local/pgsql/bin" >> ~/.zshrc'
source ~/.bashrc
source ~/.zshrc
sudo echo $PATH
ls -l /usr/local/pgsql/bin/psql
psql -U postgres -c "SELECT version();" 
git clone https://github.com/timescale/timescaledb.git
sudo dnf install cmake -y
cd ~/timescaledb
git checkout 2.13.1
export PG_INCLUDE_DIR=/usr/local/pgsql/include/server
export C_INCLUDE_PATH=/usr/local/pgsql/include/server
sudo ./bootstrap -DPOSTGRESQL_INCLUDE_DIR=/usr/local/pgsql/include/server
cd build
sudo cmake .. -DPOSTGRESQL_INCLUDE_DIR=/usr/local/pgsql/include/server
sudo make
sudo make install
sudo -u postgres /usr/local/pgsql/bin/initdb -D /var/lib/pgsql/data 
sudo env "PATH=$PATH:/usr/local/pgsql/bin/psql" psql -U postgres
sudo systemctl daemon-reload
sudo find / -name "postgresql.conf"
sudo -i -u postgres
/usr/local/pgsql/bin/pg_ctl -D /var/lib/pgsql/data start
exit
# setting  pg_hba
sudo vi /var/lib/pgsql/data/pg_hba.conf 
# local   all   postgres   trust
 
sudo $(which psql) -U postgres -c "SELECT version();"
sudo vi /etc/systemd/system/postgresql.service
sudo systemctl daemon-reload
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo systemctl status postgresql.service
sudo sh -c 'echo "shared_preload_libraries = '\''timescaledb'\''" >> /var/lib/pgsql/data/postgresql.conf'
sudo vi /var/lib/pgsql/data/postgresql.conf 
listen_addresses = '*'
port = 5432

sudo systemctl restart postgresql
sudo env "PATH=$PATH:/usr/local/pgsql/bin/psql" psql -U postgres
sudo psql -U postgres
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
cd
rm -rf timescaledb
sudo grep -E '^logging_collector[[:space:]]*=' /var/lib/pgsql/data/postgresql.conf
sudo grep -E '^log_directory[[:space:]]*=' /var/lib/pgsql/data/postgresql.conf
sudo grep -E '^log_filename[[:space:]]*=' /var/lib/pgsql/data/postgresql.conf
sudo sed -i "s/^log_filename[[:space:]]*=.*/log_filename = 'postgresql.log'/" /var/lib/pgsql/data/postgresql.conf
sudo grep -E '^log_filename[[:space:]]*=' /var/lib/pgsql/data/postgresql.conf
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-config-wizard
sudo systemctl restart postgresql
sudo -u postgres $(which psql) -c "ALTER USER postgres WITH PASSWORD 'Timescaledb2023'" 
sudo vi /var/lib/pgsql/data/pg_hba.conf 
# local   all   postgres   scram-sha-256
sudo systemctl restart postgresql
sudo -u postgres $(which psql) -U postgres -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb'"
sudo -u postgres -i sh -c 'echo $HOME'















lsb_release -a
#if ubuntu 22.04
sudo sh -c 'echo "deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get update
sudo apt-get -y install postgresql-15
psql -V
sudo sh -c 'echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -cs)-pg15 main"' >> /etc/apt/sources.list.d/timescaledb.list
source /etc/apt/sources.list.d/timescaledb.list
curl -L https://packagecloud.io/timescale/timescaledb/gpgkey | sudo apt-key add -
sudo apt update
sudo apt search timescaledb-2-oss-postgresql-15
sudo apt install timescaledb-2-oss-postgresql-15
sudo timescaledb-tune --quiet --yes
psql -U postgres -c "SELECT version();"
sudo -u postgres bash -c 'touch /var/lib/postgresql/.psql_history && chmod 600 /var/lib/postgresql/.psql_history'
sudo -u postgres sh -c 'export HOME=/var/lib/postgresql; echo $HOME'
sudo echo 'export PSQL_HISTORY=/var/lib/postgresql/.psql_history' | sudo tee -a /var/lib/postgresql/.bashrc
sudo service postgresql restart
#check status
sudo systemctl status postgresql.service
sudo nano /etc/postgresql/15/main/pg_hba.conf
local   all   postgres   trust
export PGDATA='/var/lib/postgresql/15/main'
sudo -u postgres sh -c 'cd /var/lib/postgresql && psql -c "ALTER USER postgres WITH PASSWORD '\''Timescaledb2023'\''"'
sudo systemctl reload postgresql
local   all   postgres   scram-sha-256
sudo service postgresql restart
sudo -u postgres -i sh -c 'echo $HOME'
grep postgres /etc/passwd  
sudo -u postgres psql -c "SELECT default_version FROM pg_available_extensions WHERE name = 'timescaledb';"
sudo ls /var/log/postgresql/
