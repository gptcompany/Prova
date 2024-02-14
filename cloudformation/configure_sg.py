import boto3
from botocore.exceptions import ClientError
import socket
import requests
from ipaddress import ip_network, ip_address
import functools
# Initialize the Boto3 clients for EC2 and SSM
ec2 = boto3.client('ec2')
ssm = boto3.client('ssm')
def get_instance_ip_addresses_v2():
    token_url = "http://169.254.169.254/latest/api/token"
    metadata_url_base = "http://169.254.169.254/latest/meta-data/"
    
    headers = {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}  # Token valid for 6 hours
    try:
        # Fetch the token
        token_response = requests.put(token_url, headers=headers)
        token = token_response.text
        
        # Use the token to fetch the private IP address
        private_ip_url = metadata_url_base + "local-ipv4"
        private_ip_headers = {"X-aws-ec2-metadata-token": token}
        private_ip = requests.get(private_ip_url, headers=private_ip_headers).text
        
        # Use the token to fetch the public IP address, if available
        public_ip_url = metadata_url_base + "public-ipv4"
        public_ip = requests.get(public_ip_url, headers=private_ip_headers).text
    except requests.exceptions.RequestException as e:
        print(f"Failed to fetch instance IP addresses: {e}")
        private_ip, public_ip = None, None
    
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
standby_public_ip = fetch_parameter('STANDBY_PUBLIC_IP')
ecs_instance_private_ip = fetch_parameter('ECS_INSTANCE_PRIVATE_IP')
#ecs_instance_public_ip = fetch_parameter('ECS_INSTANCE_PUBLIC_IP')
#timescaledb_public_ip = fetch_parameter('TIMESCALEDB_PUBLIC_IP')

try:
    standby_public_ip_address = socket.gethostbyname(standby_public_ip)
    print(f"The IP address for {standby_public_ip} is {standby_public_ip_address}")
except socket.gaierror:
    print(f"Could not resolve {standby_public_ip}")

# Fetching the IP addresses using IMDSv2
clustercontrol_private_ip, clustercontrol_public_ip = get_instance_ip_addresses_v2()
print(f"Private IP: {clustercontrol_private_ip if clustercontrol_private_ip else 'Not available'}")
#print(f"Public IP: {clustercontrol_public_ip if clustercontrol_public_ip else 'This instance does not have a public IP or it’s not available.'}")
def find_common_cidr(ip_list):
    # Convert IPs to binary strings
    binary_ips = [''.join(format(int(x), '08b') for x in ip.split('.')) for ip in ip_list]
    
    # Find the common prefix length
    prefix_len = 0
    for zipped in zip(*binary_ips):
        if len(set(zipped)) == 1:
            prefix_len += 1
        else:
            break
    
    # Calculate the network address by applying the common prefix and padding with zeros
    network_bin = binary_ips[0][:prefix_len].ljust(32, '0')
    network_address = '.'.join(str(int(network_bin[i:i+8], 2)) for i in range(0, 32, 8))
    
    # Combine network address with prefix length to form CIDR
    cidr = f"{network_address}/{prefix_len}"
    
    # Optionally, you can use ip_network to normalize the CIDR (e.g., remove redundant bits in the network address)
    cidr = str(ip_network(cidr, strict=False))
    
    return cidr
ips_vpc = [
    timescaledb_private_ip,
    clustercontrol_private_ip,
    ecs_instance_private_ip,
]
# Correcting the IP address format to CIDR notation
def to_cidr(ip):
    if ip and '/' not in ip:
        return ip + '/32'
    return ip

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
        # Constructing the IpRanges list with multiple CIDR blocks
        ip_permissions = [{
            'IpProtocol': protocol,
            'FromPort': from_port,
            'ToPort': to_port,
            'IpRanges': [{'CidrIp': ip_range} for ip_range in ip_ranges],
        }]
        
        # Example: This would add rules allowing access from multiple IPs/CIDRs to the same port range
        
        try:
            # First, try to remove a potentially conflicting rule that allows all traffic (0.0.0.0/0)
            # This step is optional and depends on your specific security requirements
            ec2.revoke_security_group_ingress(
                GroupId=security_group_id,
                IpPermissions=[
                    {'IpProtocol': protocol, 'FromPort': from_port, 'ToPort': to_port, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}
                ]
            )
        except Exception as e:
            print(f"Error removing existing rule for port {from_port} to {to_port}: {e}")
        
        try:
            # Then, add the new rule with specified IP ranges
            ec2.authorize_security_group_ingress(
                GroupId=security_group_id,
                IpPermissions=ip_permissions
            )
            print(f"Rules updated successfully for port {from_port} to {to_port}.")
        except Exception as e:
            if "InvalidPermission.Duplicate" in str(e):
                print(f"Rule for port {from_port} to {to_port} already exists, no action needed.")
            elif "RulesPerSecurityGroupLimitExceeded" in str(e):
                print(f"Cannot add new rule for port {from_port} to {to_port}: Security Group rule limit exceeded.")
            else:
                print(f"Error adding new rule for port {from_port} to {to_port}: {e}")



print(f"the vpc private ips: {ips_vpc}")
common_cidr = find_common_cidr(ips_vpc)
print(f"The smallest CIDR block that encompasses all IPs is: {common_cidr}")
ip_ranges = [
    common_cidr,
    to_cidr(standby_public_ip_address),  # Assuming standby_public_ip_address is the resolved IP
]
# Now, filter out any None values
ip_ranges = [ip for ip in ip_ranges if ip]
# Update security group
update_security_group_rules(security_group_id, ip_ranges, ports, protocol)
