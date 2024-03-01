cat <<EOF | sudo tee /etc/systemd/system/n8n.service
[Unit]
Description=n8n Workflow Automation
After=network.target

[Service]
Type=simple
User=ubuntu
Environment="WEBHOOK_URL=http://ec2-43-207-147-235.ap-northeast-1.compute.amazonaws.com:5678"
Environment="GENERIC_TIMEZONE=UTC"
ExecStart=/usr/local/bin/n8n
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF



sudo systemctl stop n8n
sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl restart n8n
sudo systemctl start n8n
