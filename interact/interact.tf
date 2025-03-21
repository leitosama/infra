terraform {
  required_providers {
    namecheap = {
      source = "namecheap/namecheap"
      version = ">= 2.0.0"
    }
    twc = {
      source = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
    }
  }
}

# 1. Some inputs here
variable "DOMAIN_NAME" {}
variable "SSH_KEY" {}
variable "LOCATION" {}

data "twc_os" "archlinux" {
  name = "archlinux"
  version = "1"
}

data "twc_ssh_keys" "ssh_key" {
  name = "gsa"
}


# 2. Create twc shared CPU instance

resource "twc_floating_ip" "interact_elesh_floating_ip"{
	availability_zone = var.LOCATION
}

resource "twc_server" "interact_elesh" {
	name = "Interact Elesh"
	preset_id = 2573 # TODO: Change to dynamic
	os_id = data.twc_os.archlinux.id
	availability_zone = var.LOCATION
	ssh_keys_ids = [data.twc_ssh_keys.ssh_key.id]
	floating_ip_id = twc_floating_ip.interact_elesh_floating_ip.id
}

# 3. Create domain records
resource "namecheap_domain_records" "interact_record" {
  domain = var.DOMAIN_NAME
  mode = "MERGE"
  email_type = "NONE"
  record {
    hostname = "interact"
    type = "A"
    address = twc_floating_ip.interact_elesh_floating_ip.ip
  }
  record {
    hostname = "oob"
    type = "NS"
    address = "interach.${var.DOMAIN_NAME}."
  }
}

resource "local_file" "ansible_inventory" {
  depends_on = [namecheap_domain_records.interact_record]

  filename = "${path.module}/inventory.ini"

  content = <<EOF

%{ for record in namecheap_domain_records.interact_record.record ~}
%{ if record.hostname == "interact" }
[interact]
${record.hostname}.${var.DOMAIN_NAME} ansible_host=${twc_floating_ip.interact_elesh_floating_ip.ip} ansible_user=root ansible_python_interpreter=/usr/bin/python
%{ endif }
%{ endfor ~}
EOF
}