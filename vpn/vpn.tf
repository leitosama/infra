terraform {
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.23.1"
    }
  }
}

# 1. Some inputs here
# 1.1. Variables
variable "LOCATION" {
  description = "Location code in vultr. See https://api.vultr.com/v2/regions for details"
}

variable "VULTR_API_KEY" {
  description = "VULTR API key"
}

variable "USERNAME" {
  description = "OS username"
}

variable "SSH_KEY" {
  description = "OS SSH key"
}

provider "vultr" {
    api_key = var.VULTR_API_KEY
}

# 1.2. Current data in Cloud

# 2. Create vultr shared CPU instance
resource "vultr_instance" "vpn" {
    # plan: https://api.vultr.com/v2/plans
    # vc2-1c-0.5gb-free - free tier
    # vc2-1c-1gb - min plan
    plan = "vc2-1c-1gb"
    # region: https://api.vultr.com/v2/regions
    region = var.LOCATION
    # os_id: https://api.vultr.com/v2/os
    # 391 - CoreOS Stable
    os_id = 391
    label = "${var.LOCATION}"
    tags = ["vpn"]
    hostname = "${var.LOCATION}"
    enable_ipv6 = false
    disable_public_ipv4 = false
    backups = "disabled"
    ddos_protection = false
    activation_email = false
    user_data = templatefile("${path.module}/ignition.tftpl.json", {
      hostname = var.LOCATION
      os_user = var.USERNAME
      ssh_key = var.SSH_KEY
    })   
}

# 3. Output 
output "instance_details" {
  description = "Details of the Instance"
  value = {
    ip = vultr_instance.vpn.main_ip
    os = vultr_instance.vpn.os
    region = vultr_instance.vpn.region
    status = vultr_instance.vpn.status
    hostname = vultr_instance.vpn.hostname
  }
}