# HA-infra — HA K3s Cluster on AWS (Terraform + Ansible)

Automated deployment of a highly available Kubernetes (K3s) cluster
on AWS: 3 masters (embedded etcd) + 3 workers, with ArgoCD (GitOps) and
a monitoring stack (Prometheus + Grafana).

## Architecture

- A single **VPC**, **3 AZs** (true multi-AZ), 6 subnets:
  - 3 **public** subnets (one per AZ, masters): each master has an
    Elastic IP (SSH/API access from the outside).
  - 3 **private** subnets (one per AZ, workers): Internet egress through
    a **dedicated NAT Gateway per AZ** (no public IP, no NAT
    Gateway shared across AZs).
  - Masters and workers are spread round-robin across the 3 AZs: one
    master + one worker per AZ (see `terraform output masters` /
    `terraform output workers` for the IP/AZ details of each node).
- **master1** acts as the default SSH bastion (ProxyJump), defined in
  `ansible/hosts`, to reach the workers whichever AZ they are in
  (routing inside the VPC, native between subnets of the same VPC). This
  is not a technical constraint: any master can play this
  role (shared security group, SSH allowed between nodes).
- **HA K3s**: embedded etcd, quorum across the 3 masters (spread over 3
  AZs) — losing one AZ leaves 2 active masters, a majority for
  the etcd quorum, and 2 workers.
- **cert-manager** + **Let's Encrypt** (HTTP-01 challenge via Traefik):
  automatically generates and renews TLS certificates.
- **ArgoCD** exposed through an HTTPS Traefik Ingress at `argocd.domain.com`.
- **Grafana** exposed through an HTTPS Traefik Ingress at `monitoring.domain.com`.

> The number of AZs used is controlled by `az_count` (default: 3,
> aligned with `master_count`/`worker_count`). Current resilience:
> losing one AZ = the cluster stays operational (etcd quorum
> preserved). Remaining limitation: an outage of an entire AWS region
> (rare) is out of reach for a single-region infrastructure — going
> beyond that would require cross-region replication, which is out of
> scope for this project.

## Project structure

```
ha-infra/
├── terraform/
│   ├── main.tf              # AWS infra (VPC, subnets, EC2, SG, EIP)
│   ├── .terraform.lock.hcl  # Exact provider versions (versioned)
│   └── keys/                # SSH key (gitignored, create it yourself)
│       ├── my-ssh-key
│       └── my-ssh-key.pub
├── ansible/
│   ├── ansible.cfg
│   ├── hosts                # Inventory (IPs injected by scripts/update-hosts.sh)
│   ├── site.yml             # Orchestrator (run as the 4th step)
│   ├── group_vars/
│   │   └── master/
│   │       └── vault.yml.example  # Grafana secret template (copy + encrypt)
│   └── playbooks/
│       ├── install-terraform.yml   # Optional: installs Terraform (localhost)
│       ├── install-k3s.yml
│       ├── install-cert-manager.yml # cert-manager + Let's Encrypt ClusterIssuer
│       ├── install-argocd.yml
│       ├── install-monitoring.yml
│       └── guestbook.yml           # ArgoCD demo app
├── scripts/
│   ├── update-ip.sh
│   ├── update-hosts.sh
│   └── set-domain.sh        # Replaces domain.com with your own domain
├── .gitignore
├── .gitattributes
└── README.md
```

## Prerequisites

- An AWS account with credentials configured (`~/.aws/credentials` or
  environment variables).
- Terraform installed on the control machine (or run step 0
  below to install it).
- `jq` installed (used by `scripts/update-hosts.sh`).
- An SSH key pair named `my-ssh-key` / `my-ssh-key.pub` placed
  in `terraform/keys/` (not versioned, see `.gitignore`). You can
  generate it with an ed25519 key in step 1 below.
- Ansible installed on the control machine.
- **Domain**: this project uses `argocd.domain.com` and
  `monitoring.domain.com` as examples. Replace `domain.com` with
  your own domain everywhere it appears using:
  `./scripts/set-domain.sh mydomain.com` (see step 1bis below).
- **For Let's Encrypt TLS**: the DNS records of `argocd.domain.com` and
  `monitoring.domain.com` (once replaced with your domain) must
  already point to the public IPs of the **3 masters** (one
  A record per master, EIPs given by `terraform output
  masters`) **before** running the cert-manager step — the
  HTTP-01 challenge is validated by Let's Encrypt from the outside, on port
  80, so all 3 IPs must respond. Pointing to a single master
  makes the sites unreachable if that master goes down.
- **Grafana password (ansible-vault)**: `ansible-vault` installed
  (shipped with Ansible). See step 3ter below — the monitoring
  playbook refuses to run until the password is
  configured.

## Deployment — steps

```bash
# 0. (optional) Install Terraform on this machine
cd ansible
ansible-playbook playbooks/install-terraform.yml
cd ..

# 1. Create the keys folder and generate the SSH key (ed25519)
#    -N "" = no passphrase (needed so Ansible/Terraform can use the
#    key non-interactively; add one only if you use ssh-agent)
mkdir -p terraform/keys
ssh-keygen -t ed25519 -f terraform/keys/my-ssh-key -C "my-ssh-key" -N ""
# Secure the private key (ssh-keygen already sets this, kept as a safeguard)
chmod 600 terraform/keys/my-ssh-key

# 1bis. Fix the permissions (only once): Ansible ignores ansible.cfg
#       (and therefore the inventory) if the ansible/ folder is
#       world-writable. Then make the scripts executable and replace
#       the example domain (domain.com) with yours
chmod -R go-w .
chmod 755 ansible
chmod +x scripts/update-ip.sh scripts/update-hosts.sh scripts/set-domain.sh
./scripts/set-domain.sh mydomain.com

# 2. Detect your public IP and apply the Terraform
#    (runs `terraform init`, generates terraform/terraform.tfvars
#    then runs `terraform apply`: the plan is displayed and you must
#    type "yes" to confirm; add -y to skip the confirmation)
./scripts/update-ip.sh

# 3. Inject the masters' public IPs into the ansible/hosts inventory
./scripts/update-hosts.sh

# 3bis. Point the argocd.domain.com and monitoring.domain.com DNS records to
#       the public IPs of the 3 masters (3 A records each,
#       see terraform output masters), and wait for propagation
#       before step 4.

# 3ter. Configure the Grafana password (ansible-vault, once)
cp ansible/group_vars/master/vault.yml.example ansible/group_vars/master/vault.yml
nano ansible/group_vars/master/vault.yml
# -> replace the grafana_admin_password line with a real
#    password BEFORE encrypting (otherwise the playbook will refuse to
#    continue with the placeholder value). Save (Ctrl+O,
#    Enter) then exit (Ctrl+X).
ansible-vault encrypt ansible/group_vars/master/vault.yml
# -> Ansible asks you to create a VAULT password (remember it, it is
#    different from the Grafana password): it is the one that will be
#    requested again on every --ask-vault-pass.

# 4. Deploy K3s + cert-manager/Let's Encrypt + ArgoCD + Monitoring + demo
cd ansible
ansible-playbook site.yml -e letsencrypt_email=YOUR_REAL_EMAIL@YOUR_DOMAIN.com --ask-vault-pass
```

> ⚠️ `letsencrypt_email` must be a **real email address that you
> own** (Gmail, etc.). Let's Encrypt explicitly rejects the
> `example.com` / `example.org` / `example.net` domains — using
> the placeholder as-is makes the cert-manager step fail with
> the error `forbidden domain "example.com"`.

To change the Grafana password **after** it has already been encrypted
(without starting from scratch):

```bash
export EDITOR=nano
ansible-vault edit ansible/group_vars/master/vault.yml
```

`ansible-vault edit` temporarily decrypts the file in
the chosen editor, then re-encrypts it automatically on save —
no need to run `encrypt` again by hand. Without `export EDITOR=nano`,
Ansible opens **vim** by default: to save and quit,
press `Esc` then `:wq` then `Enter` (or `:q!` to cancel without
saving).

To replay only one step (from the `ansible/` folder):

```bash
ansible-playbook site.yml --tags k3s
ansible-playbook site.yml --tags cert-manager -e letsencrypt_email=YOUR_REAL_EMAIL@YOUR_DOMAIN.com
ansible-playbook site.yml --tags argocd
ansible-playbook site.yml --tags monitoring --ask-vault-pass
ansible-playbook site.yml --skip-tags guestbook --ask-vault-pass   # everything except the demo
```

> `--ask-vault-pass` is only needed for the steps that touch
> Grafana (the password is encrypted in
> `ansible/group_vars/master/vault.yml`). Non-interactive alternative:
> `--vault-password-file=<path>` with a file
> containing the vault password (NEVER commit it, already
> covered by `.gitignore`).

> `letsencrypt_email` is only used for Let's Encrypt expiration
> alerts. If omitted, the playbook's default value
> (`changeme@domain.com`) is used — avoid it in real use.
> The `install-cert-manager.yml` playbook also creates a
> `letsencrypt-staging` ClusterIssuer (generous rate limit, certificates not trusted
> by browsers) useful for testing without consuming the strict quota of
> `letsencrypt-prod` (the only one used by default by the
> ArgoCD/Grafana Ingresses).

> The `update-ip.sh` and `update-hosts.sh` scripts locate the project on
> their own thanks to their own location (`scripts/`): they can be
> run from any folder, as long as the
> `terraform/` / `ansible/` / `scripts/` structure remains unchanged.

### Controlling the cluster from your machine (local kubectl)

On master1, `/home/ubuntu/.kube/config` points to `127.0.0.1` —
this is intentional: this file is used by all the playbooks that
run `kubectl`/`helm` **from master1 itself** (cert-manager,
ArgoCD, monitoring...). Replacing it with the public IP would break those
calls: **AWS does not allow an instance to reach itself
through its own public IP/EIP** (no hairpin NAT).

To control the cluster from your own machine, a separate **external**
kubeconfig is generated automatically during the K3s step:

```bash
scp -i terraform/keys/my-ssh-key \
  ubuntu@<MASTER1_PUBLIC_IP>:/home/ubuntu/.kube/config-external \
  ./kubeconfig-master1

export KUBECONFIG=./kubeconfig-master1
kubectl get nodes
```

### Accessing ArgoCD and Grafana

Once `ansible-playbook site.yml` has finished without errors, both
interfaces are available over HTTPS (Let's Encrypt certificate):

- **ArgoCD**: `https://argocd.<yourdomain>/`
  - User: `admin`
  - Password: automatically generated by ArgoCD at installation,
    to be retrieved with (from master1, or via the external kubeconfig):
    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d && echo
    ```
    This password is only displayed once in the Ansible logs
    during deployment (message `Display ArgoCD access
    information`) — the command above lets you
    retrieve it again at any time as long as the secret has not been changed
    or deleted.

- **Grafana**: `https://monitoring.<yourdomain>/`
  - User: `admin`
  - Password: the one you set in
    `ansible/group_vars/master/vault.yml` (step 3ter).

## Security — to know before real use

- ✅ **Port 6443 (K3s API) restricted to `allowed_ssh_cidr`** (same CIDR
  as SSH) in the security group — no more exposure to `0.0.0.0/0`.
  `scripts/update-ip.sh` automatically sets this CIDR to the public
  IP of the control machine on every run.
- ✅ **Grafana password encrypted via `ansible-vault`** (see step
  3ter) — no more plaintext password in the repo. The
  `install-monitoring.yml` playbook refuses to run if the vault is not
  configured.
- **ArgoCD over plain HTTP on the service side** (`server.insecure=true`):
  TLS is now terminated by the Traefik Ingress (Let's Encrypt),
  so **external** traffic is encrypted; only the internal path
  Ingress → `argocd-server` pod (inside the cluster) remains in the clear, which
  is acceptable within a single VPC.
- **cert-manager / Let's Encrypt**: the default `ClusterIssuer`
  used is `letsencrypt-prod`, subject to the
  [official rate limits](https://letsencrypt.org/docs/rate-limits/)
  (e.g. 5 validation failures per host/hour) — use
  `letsencrypt-staging` for repeated tests.
- **Local Terraform state**: no remote backend (S3 + DynamoDB
  lock) — add one if the project is used by a team.
- **No Kubernetes RBAC or NetworkPolicy**: the admin kubeconfig
  gives full access to the cluster, and all pods can
  communicate with each other (including across the `argocd`,
  `monitoring`, `demo` namespaces) — harden before multi-user use
  or with sensitive workloads.
- **Hard-coded AMI** (`ami_id` in `main.tf`): no mechanism for
  automatic OS security patch updates — monitor
  manually or via a regular rebuild pipeline.

## Quick troubleshooting

- `[WARNING]: Ansible is being run in a world writable directory ...
  ignoring it as an ansible.cfg source`, followed by `No inventory was
  parsed` and `[ERROR]: Error processing keyword 'hosts': object of type
  'dict' has no attribute 'master'` → Ansible refuses to read
  `ansible.cfg` from a world-writable directory (security feature), so
  `inventory = ./hosts` is never loaded and the `master` group does not
  exist. Fix the permissions of the `ansible/` folder (from the project
  root), then rerun the playbook:

  ```bash
  chmod 755 ansible
  ls -ld ansible    # should show drwxr-xr-x
  # or, for the whole project:
  chmod -R go-w .
  chmod +x scripts/*.sh
  chmod 600 terraform/keys/my-ssh-key
  ```

  This usually happens when the archive was extracted with a permissive
  umask or on a Windows-mounted drive. On WSL, keep the project inside
  the Linux filesystem (`/home/<user>/...`), not under `/mnt/c/...`.
  If you cannot change the permissions, run from `ansible/` with
  `export ANSIBLE_CONFIG=$PWD/ansible.cfg` (an explicit path is honored
  even in a world-writable directory) or pass `-i hosts`; without
  `ansible.cfg`, SSH host key checking is enabled again.
- `terraform output masters` empty/error → check that a `terraform
  apply` completed successfully in `terraform/`.
- SSH to a worker fails → check that the master used as
  bastion is reachable and that `terraform/keys/my-ssh-key` is
  `600`. Workers have no public IP: you reach them by going
  through a master (any of them). From the project root:

  ```bash
  ssh -i terraform/keys/my-ssh-key \
    -o ProxyCommand="ssh -i terraform/keys/my-ssh-key -W %h:%p ubuntu@<MASTER_PUBLIC_IP>" \
    ubuntu@<WORKER_PRIVATE_IP>
  ```

  `<MASTER_PUBLIC_IP>`: public IP of a master (`terraform output
  masters`); `<WORKER_PRIVATE_IP>`: private IP of the worker (by default
  `192.168.3.10`, `192.168.3.74`, `192.168.3.138`, see
  `terraform output workers`). The key is supplied to both connections
  (once in the main command, once in the
  `ProxyCommand`) and stays on your machine: never copy it to a
  master.
- `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` (or `Host key
  verification failed`) after recreating the cluster → the workers'
  private IPs are the same but their SSH keys have changed. Check
  that the fingerprint shown is that of the new server, then
  remove the old entry from `~/.ssh/known_hosts`:

  ```bash
  ssh-keygen -R <IP>
  # all workers (default IPs) and the masters at once:
  for ip in 192.168.3.10 192.168.3.74 192.168.3.138 <MASTER_PUBLIC_IP>; do
    ssh-keygen -R "$ip"
  done
  ```

  The masters' EIPs also change on every recreation: remove
  their old entries the same way.
- `kubectl get nodes` incomplete → rerun `ansible-playbook site.yml
  --tags k3s` from `ansible/`, the tasks are idempotent
  (`creates:` on the k3s installations).
- The `Check that the cluster is ready` task (or any
  `kubectl`/`helm` call run on master1) stays stuck on
  `FAILED - RETRYING` and never succeeds → classic symptom of a
  kubeconfig mistakenly pointing to master1's public IP instead
  of `127.0.0.1` (AWS does not support an instance reaching
  itself through its own EIP). Check that
  `/home/ubuntu/.kube/config` on master1 really uses `127.0.0.1` —
  only `/home/ubuntu/.kube/config-external` should contain the public
  IP (see the section "Controlling the cluster from your machine").
- TLS certificate never `Ready` (`kubectl describe certificate -n
  argocd argocd-server-tls` or `-n monitoring grafana-tls`) → check
  that the DNS points to the public IPs of the 3 masters and that
  port 80 is reachable from the Internet (HTTP-01 challenge); also inspect
  `kubectl describe challenge -A` and
  `kubectl logs -n cert-manager deploy/cert-manager`.
