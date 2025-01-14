terraform {
  required_providers {
    namecheap = {
      source = "namecheap/namecheap"
      version = ">= 2.0.0"
    }
    vultr = {
      source = "vultr/vultr"
      version = "2.23.1"
    }
  }
}

# 1. Some inputs here
variable "LOCATION" {
  type = list(string)
  description = "Location codes list in vultr. See https://api.vultr.com/v2/regions for details"
}

variable "USERNAME" {
  description = "OS username"
}

variable "SSH_KEY" {
  description = "OS SSH key"
}

variable "DOMAIN_NAME" {}

# 2. Create vultr shared CPU instance
resource "vultr_instance" "vpn" {
    for_each = toset(var.LOCATION)
    # plan: https://api.vultr.com/v2/plans
    # vc2-1c-0.5gb-free - free tier
    # vc2-1c-1gb - min plan
    plan = "vc2-1c-1gb"
    # region: https://api.vultr.com/v2/regions
    region = each.value
    # os_id: https://api.vultr.com/v2/os
    # 391 - CoreOS Stable
    os_id = 391
    label = "${each.value}"
    tags = ["vpn"]
    hostname = "${each.value}"
    enable_ipv6 = false
    disable_public_ipv4 = false
    backups = "disabled"
    ddos_protection = false
    activation_email = false
    user_data = templatefile("${path.module}/ignition.tftpl.json", {
      hostname = each.value
      os_user = var.USERNAME
      ssh_key = var.SSH_KEY
    })   
}

# 3. Create domain records
resource "namecheap_domain_records" "vpn_record" {
  domain = var.DOMAIN_NAME
  mode = "MERGE"
  email_type = "NONE"

  dynamic "record" {
    for_each = vultr_instance.vpn
    content {
      hostname = record.value.hostname
      type = "A"
      address = record.value.main_ip
    }
  }

}


# 3. Output 
output "instance_details" {
  description = "Details of the Instance"
  value = { for k,v in vultr_instance.vpn : k=> {
      ip = v.main_ip
      os = v.os
      region = v.region
      status = v.status
      hostname = v.hostname
    }
  }
}

resource "local_file" "ansible_inventory" {
  depends_on = [namecheap_domain_records.vpn_record]

  filename = "${path.module}/inventory.ini"

  content = <<EOF
[vpn]
%{ for instance in vultr_instance.vpn ~}
${instance.hostname}.${var.DOMAIN_NAME} ansible_host=${instance.main_ip} ansible_user=${var.USERNAME}
%{ endfor ~}
EOF
}