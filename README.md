# infra
leito.tech infra configs

## Check ansible playbooks
```bash
ansible-playbook -i ',<ip>' -e "@extra-vars.yaml" playbook.yaml -u <user>
```
- `<ip>` - ip addr of server
- `extra-vars.yaml` - extra vars
- `<user>` - ssh user