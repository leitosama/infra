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