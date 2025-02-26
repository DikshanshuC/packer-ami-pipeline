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
  default = "t2.micro"
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
} this is my .hcl file and pipeline {
    agent any

    environment {
        // Ensure this matches the region where you see your AMI
        AWS_REGION = "ap-south-1"
    }

    stages {
        stage('Checkout Code') {
            steps {
                // Pull your code from GitHub (main branch)
                git branch: 'main', url: 'https://github.com/DikshanshuC/packer-ami-pipeline.git'
            }
        }

        stage('Install Dependencies') {
            steps {
                // Requires passwordless sudo for Jenkins user, or else this will fail
                sh '''
                    echo "Installing dependencies..."
                    sudo apt-get update -y
                    sudo apt-get install -y unzip curl

                    # Install/Update AWS CLI
                    curl -LO "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
                    unzip -o awscli-exe-linux-x86_64.zip
                    sudo ./aws/install --update

                    # Install/Update Packer
                    curl -LO "https://releases.hashicorp.com/packer/1.8.2/packer_1.8.2_linux_amd64.zip"
                    unzip -o packer_1.8.2_linux_amd64.zip
                    sudo mv packer /usr/local/bin/packer
                    packer --version
                '''
            }
        }

        stage('Validate AWS Credentials') {
            steps {
                script {
                    // If you have AWS credentials in Jenkins, you can wrap this in a withCredentials() block
                    // withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-credentials']]) {
                    //     sh 'aws sts get-caller-identity'
                    // }

                    def awsIdentity = sh(script: 'aws sts get-caller-identity', returnStdout: true).trim()
                    if (!awsIdentity) {
                        error "AWS credentials not configured properly!"
                    }
                    echo "AWS Credentials Verified: ${awsIdentity}"
                }
            }
        }

        stage('Build AMI with Packer') {
            steps {
                script {
                    // Ensure the file is present
                    sh '''
                        ls -l packer.pkr.hcl || {
                            echo "packer.pkr.hcl not found!";
                            exit 1;
                        }
                    '''

                    // Initialize Packer plugins
                    sh 'packer init packer.pkr.hcl'

                    // Build the AMI, capture output
                    sh '''
                        PACKER_LOG=1 PACKER_LOG_PATH=packer_debug.log \
                        packer build -machine-readable \
                        -var "aws_region=${AWS_REGION}" \
                        packer.pkr.hcl | tee output.log
                    '''

                    // Read the output file
                    def packerOutput = readFile('output.log')

                    // Use a more flexible regex to capture the AMI ID
                    // This looks for "ami-" followed by alphanumeric chars
                    def amiIdMatch = packerOutput.find(/ami-[0-9A-Za-z]+/)

                    if (amiIdMatch) {
                        env.NEW_AMI_ID = amiIdMatch
                        echo "New AMI ID: ${env.NEW_AMI_ID}"
                    } else {
                        error "AMI ID not found in Packer output!"
                    }
                }
            }
        }

        stage('Find and Deregister Old AMI') {
            steps {
                script {
                    echo "Searching for old AMI named 'ubuntu-golden-image'..."

                    def oldAmiId = sh(script: '''
                        aws ec2 describe-images \
                            --owners self \
                            --filters "Name=name,Values=ubuntu-golden-image" \
                            --query "Images | sort_by(@, &CreationDate)[0].ImageId" \
                            --output text
                    ''', returnStdout: true).trim()

                    if (oldAmiId && oldAmiId != "None") {
                        echo "Old AMI ID: ${oldAmiId}"
                        sh "aws ec2 deregister-image --image-id ${oldAmiId}"

                        // Delete the snapshot associated with the old AMI
                        def snapshotId = sh(script: """
                            aws ec2 describe-images \
                                --image-ids ${oldAmiId} \
                                --query "Images[0].BlockDeviceMappings[0].Ebs.SnapshotId" \
                                --output text
                        """, returnStdout: true).trim()

                        if (snapshotId && snapshotId != "None") {
                            echo "Deleting Snapshot: ${snapshotId}"
                            sh "aws ec2 delete-snapshot --snapshot-id ${snapshotId}"
                        } else {
                            echo "No snapshot found or 'None' returned."
                        }
                    } else {
                        echo "No previous AMI named 'ubuntu-golden-image' found. Skipping deregistration."
                    }
                }
            }
        }
    }

    post {
        success {
            echo "✅ AMI creation and cleanup completed successfully!"
        }
        failure {
            echo "❌ Pipeline failed! Check logs for details."
        }
    }
}
