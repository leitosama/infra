# interact

## Terraform
### Setup and create
```sh
set -o allexport                                   
source .env
set +o allexport
https_proxy="socks://127.0.0.1:9050" terraform init
terraform plan -out interact.tfplan
terraform apply interact.tfplan
```

### Destroy
```sh
terraform destroy
```

## Ansible
```sh
ansible -m ping --private-key=<ssh_key> -i inventory.ini interact
ansible-playbook --private-key=<ssh_key> -i inventory.ini playbook.yaml
```