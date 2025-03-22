# Configure the AWS Provider
provider "aws" {
  region = "ap-northeast-2"
}

resource "aws_iam_user" "admin_user" {
  name = "admin"
  force_destroy = true # Destroys the user when the Terraform resource is deleted
}

resource "aws_iam_group" "admin_group" {
  name = "admin-group"
}

resource "aws_iam_group_policy_attachment" "admin_policy_attachment" {
  group      = aws_iam_group.admin_group.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_user_group_membership" "admin_user_membership" {
  user  = aws_iam_user.admin_user.name
  groups = [aws_iam_group.admin_group.name]
}

resource "aws_iam_access_key" "admin_user_access_key" {
  user = aws_iam_user.admin_user.name
}

resource "aws_iam_user_login_profile" "admin_login" {
  user                    = aws_iam_user.admin_user.name
  password_reset_required = true
}

output "admin_user_access_key" {
  value     = aws_iam_access_key.admin_user_access_key.id
  sensitive = true
}

output "admin_user_secret_key" {
  value     = aws_iam_access_key.admin_user_access_key.secret
  sensitive = true
}

#Retrieve the list of AZs in the current AWS region
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

#Define the VPC
resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr

  tags = {
    Name        = var.vpc_name
    Environment = "cka_environment"
    Terraform   = "true"
    Region      = data.aws_region.current.name
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-northeast-2a"
  map_public_ip_on_launch = true # Enables public IPs

  tags = {
    Name = "cka-public-subnet"
    Terraform = "true"
  }
}

#Create route tables for public subnet
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }
  tags = {
    Name      = "cka_public_rtb"
    Terraform = "true"
  }
}


#Create route table associations
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

#Create Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "cka_igw"
  }
}

# Terraform Data Block - To Lookup Latest Ubuntu 20.04 AMI Image
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/*/ubuntu-*-22.*-amd64-server-*"]
  }

  owners = ["099720109477"]
}

# Generate RSA Key Pair
resource "tls_private_key" "rsa_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS Key Pair using Generated RSA Key
resource "aws_key_pair" "generated_key" {
  key_name   = "k8s-node"
  public_key = tls_private_key.rsa_key.public_key_openssh
}

resource "aws_instance" "control_plane" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [aws_security_group.control_plane.id]
  subnet_id = aws_subnet.public_subnet.id

  tags = {
    Name = "control-plane"
  }
}

resource "aws_instance" "worker_nodes" {
  count         = 2
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_nodes.id]
  subnet_id = aws_subnet.public_subnet.id

  tags = {
    Name = element(["worker-node-1", "worker-node-2"], count.index)
  }
}


# Output Private Key (Save manually)
output "private_key_pem" {
  value     = tls_private_key.rsa_key.private_key_pem
  sensitive = true
}

output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
  description = "The public IP of the control plane instance"
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
  description = "The private IP of the control plane instance"
}

output "worker_nodes_public_ip" {
   value = { for i, instance in aws_instance.worker_nodes : instance.tags["Name"] => instance.public_ip }
  description = "The public IP of the worker instance"
}

output "worker_nodes_private_ip" {
   value = { for i, instance in aws_instance.worker_nodes : instance.tags["Name"] => instance.private_ip }
  description = "The private IP of the worker instance"
}

# output "public_ips" {
#   value = { for i, instance in aws_instance.control_plane : instance.tags["Name"] => instance.public_ip }
# }


# output "private_ips" {
#   value = { for i, instance in aws_instance.cka_ec2_instances : instance.tags["Name"] => instance.private_ip }
# }

resource "aws_security_group" "control_plane" {
  name        = "control-plane-sg"
  description = "Security group for the control plane"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "Allow 22 for ssh connection"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow etcd server communication"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "Allow Cilium agent communication (Hubble Relay)"
    from_port   = 4240
    to_port     = 4240
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

   ingress {
    description = "Cilium health check"
    from_port   = 4244
    to_port     = 4244
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "Allow inbound traffic for Kubernetes API server (kubectl access)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Cilium VXLAN and Geneve overlay network"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }


  ingress {
    description = "Allow kubelet API and health check"
    from_port   = 10250
    to_port     = 10255
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "Allow kube-controller-manager"
    from_port   = 10257
    to_port     = 10257
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "Allow kube-scheduler"
    from_port   = 10259
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "Cilium WireGuard encryption"
    from_port   = 51871
    to_port     = 51871
    protocol    = "udp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

  resource "aws_security_group" "worker_nodes" {
  name        = "worker-nodes-sg"
  description = "Security group for worker nodes"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "Allow 22 for ssh connection"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow kubelet API and health check"
    from_port   = 10250
    to_port     = 10255
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

   ingress {
    description = "Allow kube-scheduler"
    from_port   = 10259
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }

  ingress {
    description = "NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }


  tags = {
    Name    = "web_server_inbound"
    Purpose = "Intro to Resource Blocks Lab"
  }
}
