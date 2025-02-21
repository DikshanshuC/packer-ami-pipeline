packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.0.0"
    }
  }
}

variable "aws_region" {
  default = "ap-south-1"
}

variable "ami_name" {
  default = "ubuntu-golden-image"
}

variable "instance_type" {
  default = "t2.small"
}

source "amazon-ebs" "ubuntu" {
  region             = var.aws_region
  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"] 
    most_recent = true
  }
  instance_type      = var.instance_type
  ssh_username       = "ubuntu"
  ami_name           = var.ami_name
}

build {
  sources = ["source.amazon-ebs.ubuntu"]

  provisioner "shell" {
    inline = [
      "sudo apt update && sudo apt upgrade -y",
      "sudo apt install -y openjdk-17-jdk openjdk-11-jdk openjdk-21-jdk",
      "sudo apt install -y curl unzip ca-certificates htop",
      
      "sudo wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key",
      "echo 'deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/' | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null",
      "sudo apt-get update",
      "sudo apt-get install -y jenkins",
      "jenkins --version",
      
      "sudo apt install -y docker.io",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "docker --version",
      
      "curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\"",
      "unzip awscliv2.zip",
      "sudo ./aws/install",
      "aws --version",
      
      "sudo usermod -aG docker jenkins",
      "sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
    ]
  }
}
