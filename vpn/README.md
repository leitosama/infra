# VPN

## Terraform
### Setup and create
```sh
set -o allexport                                   
source .env
set +o allexport
cp vpn.tfvars.example vpn.tfvars
vim vpn.tfvars
https_proxy="socks://127.0.0.1:9050" terraform init
terraform plan -var-file vpn.tfvars -out vpn.tfplan
terraform apply vpn.tfplan
```

### Destroy
```sh
terraform destroy
```

## Install python
```sh
ssh <user>@<host> 'sudo rpm-ostree install python && sudo systemctl reboot'
```

## Ansible
```sh
ansible -m ping --private-key=<ssh_key> -i inventory.ini vpn
ansible-playbook --private-key=<ssh_key> -i inventory.ini outline.yaml
```