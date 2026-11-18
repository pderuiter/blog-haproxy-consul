# blog-haproxy-consul

Companion code for the blog post
[HAProxy and Consul: Dynamic Service Discovery for Load Balancing](https://blog.bsdserver.nl/haproxy-and-consul-dynamic-service-discovery-for-load-balancing/).

It builds the post's setup: a three-server Consul 2.1.0 cluster with ACLs (default deny),
a service node that registers the post's `web` (port 8080) and `api` (port 3000) services,
and an HAProxy load balancer where consul-template 0.43.1 renders `haproxy.cfg` from the
Consul catalog and reloads HAProxy whenever services come, go or change health.
HAProxy comes from the official HAProxy packages (the vbernat PPA on Ubuntu).

## What is in here

| Path | Purpose |
|------|---------|
| `terraform/` | Five Ubuntu 24.04 VMs on Proxmox VE (bpg/proxmox provider, cloud-init), outputs an Ansible inventory |
| `ansible/site.yml` | One playbook for the whole setup |
| `ansible/roles/consul` | Consul binary, `consul.hcl` (server or client, as in the post), systemd unit |
| `ansible/roles/consul_acl` | The post's "Bootstrapping ACLs": bootstrap, `agent` and `consul-template` policies and tokens, `set-agent-token agent/default` on every agent |
| `ansible/roles/consul_services` | `web-service.hcl` and `api-service.hcl` from the post |
| `ansible/roles/haproxy_install` | HAProxy from the official repositories (vbernat PPA / haproxy.debian.net) |
| `ansible/roles/consul_template` | consul-template, its config with the ACL token, the post's `haproxy.ctmpl`, systemd unit |
| `ansible/roles/demo_backend` | **Lab/demo only**: a tiny Python HTTP server on 8080 and 3000 so the health checks pass |

## Requirements

- Terraform >= 1.6 and a Proxmox VE API token (only if you want Terraform to create the VMs)
- ansible-core >= 2.15 (tested with the current ansible-core release)
- Target hosts: Ubuntu 24.04, reachable from each other on the Consul ports (8300-8302, 8500, 8502, 8503)

## Quick start

```bash
# 1. Machines (optional; skip if you already have five hosts)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.yml

# 2. Secrets: four fresh UUIDs for the agent and consul-template tokens
cd ../ansible
cp inventory.example.yml inventory.yml         # if you skipped Terraform
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
for i in 1 2 3 4; do uuidgen; done              # paste them into vault.yml
ansible-vault encrypt group_vars/all/vault.yml

# 3. Consul, services, HAProxy
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass

# 4. Test (on the load balancer)
curl -H "Host: example.com" http://localhost/
curl -H "Host: api.example.com" http://localhost/api/health
grep -A6 '^backend web_servers' /etc/haproxy/haproxy.cfg
```

Register another `web` instance on a service node (post section "Dynamic Registration via
HTTP API", with the agent token in `X-Consul-Token`) and it appears in `backend web_servers`
within the consul-template wait time (5-10 s); deregister it and it disappears again.

The bootstrap (management) token stays on the first Consul server in
`/root/consul-acl-bootstrap.json` (root only). Use it for `consul acl ...` administration.

## Groups and variables

| Group | Hosts | Roles |
|-------|-------|-------|
| `consul_servers` | 3 | consul (server), consul_acl |
| `consul_service_nodes` | 1 or more | consul (client), demo_backend, consul_services |
| `haproxy_lb` | 1 | consul (client), haproxy_install, consul_template |

Set in `ansible/group_vars/all/vars.yml` (defaults in each role's `defaults/main.yml`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `consul_version` | `2.1.0` | Consul release from releases.hashicorp.com; changing it upgrades the binary |
| `consul_template_version` | `0.43.1` | consul-template release |
| `consul_datacenter` | `dc1` | Datacenter name |
| `consul_bind_network` | `10.0.0.0/8` | Agents bind to their address in this network (`GetPrivateInterfaces`, as in the post) |
| `consul_retry_join` | addresses of `consul_servers` | What the agents join |
| `consul_enable_local_script_checks` | `false` | Needed only for script checks |
| `haproxy_install_version` | `3.3` | HAProxy branch; `3.2` for LTS on Ubuntu 24.04 |
| `demo_backend_enabled` | `true` | Lab/demo backend on the service nodes; set `false` for real services |
| `vault_consul_*_token_accessor` / `_secret` | (vault) | Fixed AccessorID/SecretID of the agent and consul-template tokens |

The post's template binds `*:443` with `crt /etc/haproxy/certs/`. When that directory has
no certificate, the role creates a self-signed placeholder (`selfsigned.pem`); replace it
with your own certificate.

## Terraform variables

See `terraform/variables.tf` and `terraform/terraform.tfvars.example`. The VMs are defined in
the `vms` map (name, IP in CIDR notation, Ansible groups, optional cores/memory/disk).

## Tested

`site.yml` was run against fresh Ubuntu 24.04 systemd containers (three servers, one service
node, one load balancer; Consul 2.1.0, consul-template 0.43.1, HAProxy 3.3.17). The second
run reports `changed=0`. After the run, `consul members` lists all five agents, HAProxy
serves the `web` and `api` backends, and registering and then deregistering an extra `web`
instance adds and removes it from HAProxy. ansible-lint (production profile), yamllint,
`terraform validate` and tflint are clean. The Terraform code has not been applied against a
real Proxmox cluster.

Restarting all three servers at once (for example after changing `consul.hcl` everywhere)
briefly loses the raft quorum; run with `--forks 1` or `serial` if that matters to you.

## License

MIT
