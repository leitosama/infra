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

provider "vultr" {
    api_key = var.VULTR_API_KEY
}

# 1.2. Current data in Cloud

# 2. Create vultr shared CPU instance
resource "vultr_instance" "my_instance" {
    # plan: https://api.vultr.com/v2/plans
    plan = "vc2-1c-2gb"
    # region: https://api.vultr.com/v2/regions
    region = var.LOCATION
    # os_id: https://api.vultr.com/v2/os
    # 391 - CoreOS Stable
    os_id = 391
    label = "vpn-${var.LOCATION}"
    tags = ["vpn"]
    hostname = "vpn-${var.LOCATION}"
    enable_ipv6 = false
    disable_public_ipv4 = false
    backups = "enabled"
    backups_schedule {
            type = "daily"
    }
    ddos_protection = true
    activation_email = false
}
