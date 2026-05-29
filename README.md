# SDS Inject Project — Air-gapped Kubernetes installer

A single self-extracting `.run` file that brings up a Kubernetes cluster on an air-gapped Ubuntu machine, with CI/CD around it.

The installer bundles all binaries, container images, and configuration. Once built, it can be copied to any compatible target and run with no internet connectivity. CI validates and produces it, CD deploys it.

---

## Architecture

The project has a deliberate split between the **build side** (which has internet) and the **target side** (which does not):

```
+-----------------------------+        +------------------------------+
|        BUILD SIDE           |        |        TARGET SIDE           |
|  (CI runner — has internet) |        |   (air-gapped — no internet) |
+-----------------------------+        +------------------------------+
| build-script    downloads:  |        | k8s-installer.run            |
|   kubeadm, kubelet, kubectl |        |   (single file, ~164 MB)     |
|   containerd, runc, CNI     |        |                              |
|   helm, kustomize           |        | -- contains --               |
|                             |        | automation-scripts/          |
| gather-images.sh pulls:     |        | binaries/                    |
|   k8s control plane images  |        | configs/                     |
|   Flannel CNI images        |        | install.sh (wrapper)         |
|                             |        |                              |
| package-script wraps it all |        | Runs:                        |
| with makeself ─────────────────────►|  install-k8s.sh --role <role> |
|                             |        |  → master  → kubeadm init    |
|                             |        |  → worker  → kubeadm join    |
+-----------------------------+        +------------------------------+
```

The installer is reproducible: every dependency is version-pinned, downloaded from official sources, and bundled. The target machine never needs to reach the internet.

---

## Folder structure

```
sds-inject-project/
├── automation-scripts/      # Modular install scripts
│   ├── install-k8s.sh       # The main installer 
│   └── gather-images.sh     # Pulls + exports container images
├── binaries/                # Populated by build-script (gitignored)
│   ├── k8s/                 # kubeadm, kubelet, kubectl
│   ├── runtime/             # containerd, runc, CNI plugins
│   ├── tools/               # helm, kustomize
│   └── images/              # Container image .tar files
├── cd/
│   └── deploy.sh            # CD's deploy logic (SSH + role detection)
├── configs/                 # Declarative configuration (IaaC)
│   ├── containerd.service   # systemd unit
│   ├── kubeadm-config.yaml  # kubeadm cluster bootstrap
│   └── kube-flannel.yml     # Flannel CNI manifest
├── logs/                    # Runtime logs (gitignored)
├── .github/workflows/
│   ├── ci.yml               # Validate, build, publish to Releases
│   └── cd.yml               # Download Release, SSH, deploy
├── build-script             # Downloads binaries
├── package-script           # Wraps everything into the .run via makeself
└── README.md
```

A few notes on the layout:

- **`binaries/` contents are gitignored.** Git holds source (scripts, configs, IaaC); built binaries live in GitHub Releases (storage). Build-script regenerates the folder per CI run.
- **`.github/workflows/` instead of `ci/` and `cd/yml`.** GitHub Actions requires this fixed path; `cd/` holds the deploy script invoked by `cd.yml`.
- **IaaC lives under `configs/`** — kubeadm-config.yaml, kube-flannel.yml, and the systemd unit are all declarative configuration version-controlled with the project.

---

## Quick start

### Build the installer locally

On any machine with internet, makeself, and (for image gathering) containerd:

```bash
git clone https://github.com/ayra1216-git/sds-inject-project.git
cd sds-inject-project
./build-script                              # downloads binaries
sudo ./automation-scripts/gather-images.sh  # pulls images via containerd
./package-script                            # produces k8s-installer.run
```

The result is `k8s-installer.run`, ~300 MB. It runs anywhere on Ubuntu 22.04+ x86_64.

### Run the installer on an air-gapped target

```bash
scp k8s-installer.run user@target:/tmp/      # over any network the target has
ssh user@target
chmod +x /tmp/k8s-installer.run
sudo /tmp/k8s-installer.run -- --role master
```

Or for a worker:

```bash
sudo /tmp/k8s-installer.run -- --role worker --join-command "kubeadm join ..."
```

### Deploy via CD

In GitHub: **Actions → deploy-installer → Run workflow** with the target host and SSH user. CD downloads the latest Release, SSH'es to the target, detects whether Kubernetes is already installed, and acts accordingly.

---

## Pinned versions

Every dependency is pinned. 

| Component | Version |
|---|---|
| Kubernetes (master baseline) | v1.35.5 |
| Kubernetes (worker upgrade) | v1.36.1 |
| containerd | 2.0.2 |
| runc | v1.2.4 |
| CNI plugins | v1.6.2 |
| helm | v3.17.0 |
| kustomize | v5.6.0 |
| Flannel CNI | v0.27.0 |

The "worker upgrade" version is the deliberate two-minor-version offset (1.35 → 1.36) used to demonstrate CD's "reinstall newer version on workers" branch while respecting Kubernetes' version skew rules.

---

### What self-healing means in this project

A pattern used throughout the install script:

1. Do the thing (e.g., set a sysctl value, mask a unit, write a config)
2. Verify it took effect
3. If not, attempt to remediate (e.g., re-apply, unmask, append)
4. Verify again
5. If still wrong, exit with a clear error and a suggested fix

Examples in the code: `prep_swap`, `prep_modules`, `prep_sysctl`, `install_containerd` (SystemdCgroup append fallback), `import_images`.

---

## Issues encountered during development

These came up while building the project.

### containerd `SystemdCgroup = false` not being replaced

The script ran `sed 's/SystemdCgroup = false/.../' config.toml` and continued silently. Some containerd config versions don't ship the line at all — sed had nothing to replace. The kubelet then refused to start because of cgroup driver mismatch.

**Fix:** verify after sed, and if the line is missing, append it under `[plugins...runc.options]`. Then verify again. 


### Missing `kubelet.service.d/10-kubeadm.conf`

When kubelet is installed via apt, the package provides this drop-in. When installed from raw binaries (as we do for air-gap), it's missing. kubelet then starts in "Standalone mode, no API client" and `kubeadm init` can't bootstrap.

**Fix:** the script writes the drop-in itself with the exact environment variables kubeadm expects.


### API server binding to IPv6 only

Without an explicit `localAPIEndpoint.advertiseAddress`, kubeadm let the API server bind to all interfaces — which on this Ubuntu kernel meant tcp6 only, not tcp4. Flannel's pods then couldn't reach `10.96.0.1:443` (the Kubernetes service IP) because the iptables rule's destination wasn't actually answering on IPv4.

**Fix:** detect the primary IP at runtime and write it into a generated kubeadm-config.yaml, so the API server has an explicit IPv4 bind address.


### package-script using relative paths

`package-script` did `cp -r binaries/ staging/` — relative to whatever directory it was called from. CI's directory handling sometimes meant `binaries/images/` was looked up from the wrong place, producing an installer with the folder structure but no image .tar files.

**Fix:** use `"$SCRIPT_DIR/binaries/"` (absolute) everywhere, and fail-fast if `binaries/images/` is empty before bundling. The empty-folder case used to be a silent build of a broken installer; now it's a loud error.

### root-owned workspace breaking next CI checkout

CI ran `sudo ./package-script` and `sudo ./gather-images.sh`. Files created by these end up owned by root in the workspace. The next CI run's checkout step (which runs as the runner user) couldn't delete those files and failed with EACCES.

**Fix:** add a final CI step `sudo chown -R vboxuser:vboxuser "${{ github.workspace }}"` with `if: always()`. Runs even on failure to keep the workspace clean.

---

## Limitations and production considerations

These are deliberate trade-offs made for the take-home. In production, each would be handled differently.

### Self-hosted runner is manually configured

The runner VM has containerd, makeself, shellcheck, gh, and the runner agent installed by hand. In production this would be either a pre-baked image (Packer) or configured via Ansible/cloud-init.

### CD requires the target to be reachable from the runner

Works fine when both run in the same private network. In production with multiple targets across networks, you'd either:
- Use a runner inside each target's network
- Use a bastion/jump host
- Run the deploy logic from a control plane (Spacelift, ArgoCD, Atlantis)

### Worker version bump is documented, not actually built

The pipeline produces one installer per build, pinned to v1.35.5. The "newer version" for worker upgrades is documented as v1.36.1; in practice, building it would be the same pipeline running against a tag with bumped `K8S_VERSION`. Not done because the assignment doesn't require running the full upgrade scenario, only demonstrating the logic.

### No SSL/auth on the API server beyond defaults

kubeadm's defaults are fine for a single-machine cluster. Production would harden with custom certs, audit logging, admission controllers, restricted RBAC, etc. Out of scope here.

### Single-node cluster

The installer supports master + worker, but the demo is a single master (which kubeadm allows after untainting). A real cluster would have 3 masters for control-plane HA. Achievable with this installer by running `--role master` on additional control-plane nodes with `--upload-certs` shared via the join command.

---

## Verification

After a clean deploy via CD, on the target:

```bash
$ sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
NAME         STATUS   ROLES           AGE   VERSION
k8subuntu    Ready    control-plane   2m    v1.35.5

$ sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A
NAMESPACE      NAME                                READY   STATUS    AGE
kube-flannel   kube-flannel-ds-xxxx                1/1     Running   1m
kube-system    coredns-xxxx                        1/1     Running   1m
kube-system    coredns-yyyy                        1/1     Running   1m
kube-system    etcd-k8subuntu                      1/1     Running   2m
kube-system    kube-apiserver-k8subuntu            1/1     Running   2m
kube-system    kube-controller-manager-k8subuntu   1/1     Running   2m
kube-system    kube-proxy-xxxx                     1/1     Running   2m
kube-system    kube-scheduler-k8subuntu            1/1     Running   2m

$ helm version
$ kustomize version
```

The control plane is up, Flannel provides the pod network, CoreDNS resolves cluster DNS, and the additional tools (helm, kustomize) are installed alongside.
