# blog-haproxy-consul

Companion code for the blog post
[HAProxy and Consul: Dynamic Service Discovery for Load Balancing](https://blog.bsdserver.nl/haproxy-and-consul-dynamic-service-discovery-for-load-balancing/).

It builds the post's setup: a three-server Consul 2.1.0 cluster with ACLs (default deny),
a service node that registers the post's `web` (port 8080) and `api` (port 3000) services,
and an HAProxy load balancer where the HAProxy Data Plane API 3.4.7 watches Consul (its
built-in Consul service discovery) and creates one backend per service, adding and
removing servers as instances come, go or change health. No consul-template.
HAProxy comes from the official HAProxy packages (the vbernat PPA on Ubuntu).

## What is in here

| Path | Purpose |
|------|---------|
| `terraform/` | Five Ubuntu 24.04 VMs on Proxmox VE (bpg/proxmox provider, cloud-init), outputs an Ansible inventory |
| `ansible/site.yml` | One playbook for the whole setup |
| `ansible/roles/consul` | Consul binary, `consul.hcl` (server or client, as in the post), systemd unit |
| `ansible/roles/consul_acl` | The post's "Bootstrapping ACLs": bootstrap, the `agent` policy and token, the read-only `dataplaneapi` policy and token, `set-agent-token agent/default` on every agent |
| `ansible/roles/consul_services` | `web-service.hcl` and `api-service.hcl` from the post |
| `ansible/roles/haproxy_install` | HAProxy from the official repositories (vbernat PPA / haproxy.debian.net) |
| `ansible/roles/dataplaneapi` | Base `haproxy.cfg` (frontend + `defaults consul_services`), `hosts.map`, Data Plane API binary, config and unit, and the Consul registration (`POST /v3/service_discovery/consul`, `PUT` when settings change) |
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

# 2. Secrets: four UUIDs for the agent and Data Plane API tokens, and the API password
cd ../ansible
cp inventory.example.yml inventory.yml         # if you skipped Terraform
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
for i in 1 2 3 4; do uuidgen; done              # paste them into vault.yml
mkpasswd -m sha-512                             # hash of the API password (package whois)
ansible-vault encrypt group_vars/all/vault.yml

# 3. Consul, services, HAProxy
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass

# 4. Test (on the load balancer)
curl -H "Host: www.example.com" http://localhost/    # web
curl -H "Host: api.example.com" http://localhost/    # api
grep -A3 '^backend consul-backend' /etc/haproxy/haproxy.cfg
```

The backends are named `consul-backend-<consul address>-<consul port>-<service>`, here
`consul-backend-127.0.0.1-8500-web` and `...-api`. Register another `web` instance on a
service node (post section "Dynamic Registration via HTTP API", with a token in
`X-Consul-Token`) and it gets a server in that backend within `retry_timeout` (5 s);
deregister it, or let its check fail, and it is removed again.

The frontend picks the service from `/etc/haproxy/maps/hosts.map` (Host header -> service
name; unknown hosts go to `web`). Change or add routes without a reload, for example a
blue-green switch:

```bash
curl -u admin -X PUT -H "Content-Type: application/json" \
  "http://127.0.0.1:5555/v3/services/haproxy/runtime/maps/hosts.map/entries/www.example.com?force_sync=true" \
  -d '{"value":"web-green"}'
```

The Data Plane API owns `haproxy.cfg` once it runs, and the runtime maps API owns
`hosts.map`. The role writes `haproxy.cfg` only while it is still the packaged one (no
`# Dataplaneapi managed File` header) and `hosts.map` only when it is missing.

The bootstrap (management) token stays on the first Consul server in
`/root/consul-acl-bootstrap.json` (root only). Use it for `consul acl ...` administration.

## Groups and variables

| Group | Hosts | Roles |
|-------|-------|-------|
| `consul_servers` | 3 | consul (server), consul_acl |
| `consul_service_nodes` | 1 or more | consul (client), demo_backend, consul_services |
| `haproxy_lb` | 1 | consul (client), haproxy_install, dataplaneapi |

Set in `ansible/group_vars/all/vars.yml` (defaults in each role's `defaults/main.yml`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `consul_version` | `2.1.0` | Consul release from releases.hashicorp.com; changing it upgrades the binary |
| `dataplaneapi_version` | `3.4.7` | Data Plane API release; changing it upgrades the binary |
| `dataplaneapi_consul_services` | `[web, api]` | `service_allowlist`: the services that get a backend |
| `dataplaneapi_consul_health_check_policy` | `all` | `none`, `any`, `all` or `min`: which instances become servers |
| `dataplaneapi_consul_server_slots_base` / `_growth_type` / `_growth_increment` | `10` / `linear` / `10` | Server lines per backend, and how they grow |
| `dataplaneapi_routes` / `dataplaneapi_default_service` | `www.example.com -> web`, `api.example.com -> api` / `web` | Initial `hosts.map` and the service for unknown hosts |
| `consul_datacenter` | `dc1` | Datacenter name |
| `consul_bind_network` | `10.0.0.0/8` | Agents bind to their address in this network (`GetPrivateInterfaces`, as in the post) |
| `consul_retry_join` | addresses of `consul_servers` | What the agents join |
| `consul_enable_local_script_checks` | `false` | Needed only for script checks |
| `haproxy_install_version` | `3.3` | HAProxy branch; `3.2` for LTS on Ubuntu 24.04 |
| `demo_backend_enabled` | `true` | Lab/demo backend on the service nodes; set `false` for real services |
| `vault_consul_*_token_accessor` / `_secret` | (vault) | Fixed AccessorID/SecretID of the agent and Data Plane API tokens |
| `vault_dataplaneapi_password` / `_hash` | (vault) | API password (for the role's API calls) and its SHA-512 hash (for `dataplaneapi.yaml`) |

The API listens on `127.0.0.1:5555` only. Open it up (and add TLS) only if a remote
controller needs it.

## Terraform variables

See `terraform/variables.tf` and `terraform/terraform.tfvars.example`. The VMs are defined in
the `vms` map (name, IP in CIDR notation, Ansible groups, optional cores/memory/disk).

## Tested

`site.yml` was run against fresh Ubuntu 24.04 systemd containers (three servers, one service
node, one load balancer; Consul 2.1.0, Data Plane API 3.4.7, HAProxy 3.3.17). The second
run, and a run after restarting HAProxy and the API, report `changed=0`; changing
`dataplaneapi_consul_health_check_policy` updates the registration (`changed=1`, then 0).
HAProxy serves the `web` and `api` backends; an extra `web` instance is added on register,
removed when its check fails, added back when it heals and removed on deregister, each
time with one seamless HAProxy reload. Changing a `hosts.map` entry through the runtime
maps API switches traffic without a reload, and the next run stays at `changed=0`. The
Data Plane API token gets 403 on a KV write. ansible-lint (production profile), yamllint,
`terraform validate` and tflint are clean. The Terraform code has not been applied against a
real Proxmox cluster.

Restarting all three servers at once (for example after changing `consul.hcl` everywhere)
briefly loses the raft quorum; run with `--forks 1` or `serial` if that matters to you.

## License

MIT
