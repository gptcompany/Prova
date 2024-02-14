import boto3
from botocore.exceptions import ClientError
import socket
import requests
# Initialize the Boto3 clients for EC2 and SSM
ec2 = boto3.client('ec2')
ssm = boto3.client('ssm')
def get_instance_ip_addresses():
    # URL for the metadata service to fetch IP addresses
    metadata_url_base = "http://169.254.169.254/latest/meta-data/"
    
    # Fetch the private IP address
    private_ip_url = metadata_url_base + "local-ipv4"
    private_ip = requests.get(private_ip_url).text
    
    # Fetch the public IP address
    public_ip_url = metadata_url_base + "public-ipv4"
    try:
        public_ip = requests.get(public_ip_url).text
    except requests.exceptions.RequestException:
        # In case there's no public IP assigned, handle the exception
        public_ip = "No public IP assigned"
    
    return private_ip, public_ip
# Function to fetch a parameter from SSM
def fetch_parameter(name):
    try:
        response = ssm.get_parameter(Name=name, WithDecryption=True)
        return response['Parameter']['Value']
    except ClientError as e:
        if e.response['Error']['Code'] == 'ParameterNotFound':
            print(f"Parameter {name} not found.")
        elif e.response['Error']['Code'] == 'AccessDeniedException':
            print(f"Access denied when fetching parameter {name}.")
        else:
            print(f"An error occurred: {e.response['Error']['Message']}")
        return None
    except Exception as e:
        print(f"Unexpected error when fetching parameter {name}: {str(e)}")
        return None

# Fetching security group ID and IP addresses from SSM
security_group_id = fetch_parameter('SECURITY_GROUP_ID')
timescaledb_private_ip = fetch_parameter('TIMESCALEDB_PRIVATE_IP')
timescaledb_public_ip = fetch_parameter('TIMESCALEDB_PUBLIC_IP')
standby_public_ip = fetch_parameter('STANDBY_PUBLIC_IP')
try:
    standby_public_ip_address = socket.gethostbyname(standby_public_ip)
    print(f"The IP address for {standby_public_ip} is {standby_public_ip_address}")
except socket.gaierror:
    print(f"Could not resolve {standby_public_ip}")
ecs_instance_private_ip = fetch_parameter('ECS_INSTANCE_PRIVATE_IP')
ecs_instance_public_ip = fetch_parameter('ECS_INSTANCE_PUBLIC_IP')
# Fetching the IP addresses
clustercontrol_private_ip, clustercontrol_public_ip = get_instance_ip_addresses()
print(f"Private IP: {clustercontrol_private_ip}")
print(f"Public IP: {clustercontrol_public_ip if clustercontrol_public_ip != 'No public IP assigned' else 'This instance does not have a public IP.'}")

# Define your IP ranges including the fetched IPs
ip_ranges = [
    timescaledb_private_ip,
    timescaledb_public_ip,
    standby_public_ip,
    ecs_instance_private_ip,
    ecs_instance_public_ip,
    clustercontrol_private_ip,
    clustercontrol_public_ip
]

# Example ports to allow, including handling for port ranges
ports = [
    (5432, 5432),
    (9500, 9500),
    (9990, 9999),  # Port range represented as a tuple (start, end)
    (9001, 9001),
    (443, 443),
    (5678, 5678),
    (3306, 3306),
    (80, 80),
    (22, 22),
    (5901, 5901),
    (26379, 26379),
    (8501, 8501),
    (9090, 9090),
    (8000, 8000),
    (6379, 6379),
    (3000, 3000)
]
protocol = 'tcp'  # Adjust as necessary

# Function to update security group inbound rules
def update_security_group_rules(security_group_id, ip_ranges, ports, protocol):
    for port_range in ports:
        from_port, to_port = port_range
        ip_permissions = [{
            'IpProtocol': protocol,
            'FromPort': from_port,
            'ToPort': to_port,
            'IpRanges': [{'CidrIp': ip_range} for ip_range in ip_ranges],
        }]
        
        # Remove the existing rule that allows all traffic for this port from 0.0.0.0/0, if necessary
        # It's a good practice to handle exceptions here as there might not be a matching rule
        try:
            ec2.revoke_security_group_ingress(
                GroupId=security_group_id,
                IpPermissions=[{
                    'IpProtocol': protocol,
                    'FromPort': from_port,
                    'ToPort': to_port,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0'}],
                }]
            )
        except Exception as e:
            print(f"Error removing existing rule for port {from_port - to_port}: {e}")

        # Add new rules for specified IP ranges
        try:
            ec2.authorize_security_group_ingress(
                GroupId=security_group_id,
                IpPermissions=ip_permissions
            )
            print(f"Rules updated successfully for port {from_port - to_port}:.")
        except Exception as e:
            print(f"Error adding new rule for port {from_port - to_port}:: {e}")

# Update security group
update_security_group_rules(security_group_id, ip_ranges, ports, protocol)
