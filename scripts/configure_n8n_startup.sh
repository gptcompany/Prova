cat <<EOF | sudo tee /etc/systemd/system/n8n.service
[Unit]
Description=n8n Workflow Automation
After=network.target

[Service]
Type=simple
User=ubuntu
ExecStart=/usr/local/bin/n8n
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl start n8n
