# ---------------------------------------------------------------------------
# Web-base AMI: stock Ubuntu 26.04 with the heavy provisioning pre-baked
# (system upgrade, Apache/PHP stack, AWS CLI, exporter binaries).
#
# Build:   cd packer && packer init . && packer build .
# Use:     set web_ami_id = "<ami id from the build output>" in
#          terraform.tfvars, then terraform apply (the ASG instance refresh
#          rolls it out gradually).
#
# The runtime setup script (scripts/web_server_setup.sh) is idempotent and
# skips work already baked in, so instances boot in seconds instead of
# minutes and no longer depend on apt mirrors / GitHub at launch.
# ---------------------------------------------------------------------------

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "project_name" {
  type    = string
  default = "webapp"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

source "amazon-ebs" "web_base" {
  region        = var.aws_region
  instance_type = var.instance_type
  ssh_username  = "ubuntu"
  ami_name      = "${var.project_name}-web-base-{{timestamp}}"

  # Same source image the Terraform data source uses
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name      = "${var.project_name}-web-base"
    Role      = "web-base"
    BuiltWith = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.web_base"]

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    script          = "bake-web-base.sh"
  }
}
