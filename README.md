# IOT

This project is a practical introduction to modern infrastructure and DevOps workflows. It progresses from provisioning virtual machines and building a multi-node **K3s** cluster to deploying containerized applications on **Kubernetes**, exposing them through Ingress, and managing deployments with **Argo CD** GitOps automation. The bonus implementation extends the workflow with a local **GitLab** instance as the source repository for continuous application synchronization.

## Project layout

| Directory | Description |
| --- | --- |
| `p1/` | Creates a two-node K3s cluster with one server and one worker. |
| `p2/` | Creates a single-node K3s cluster and deploys three Nginx applications behind an Ingress. |
| `p3/` | Creates a local K3d cluster, installs Argo CD, and synchronizes manifests from GitHub. |
| `bonus/` | Runs GitLab locally and uses it as the Git source for an Argo CD application. |

## Prerequisites

Install the tools required by the exercise you want to run:

- [Vagrant](https://developer.hashicorp.com/vagrant)
- [VirtualBox](https://www.virtualbox.org/) for `p1` and `p2`
- Docker for `p3` and `bonus`
- `curl`, `git`, and a Linux environment

The provisioning scripts install K3s, K3d, `kubectl`, Helm, and Argo CD components when needed. Internet access is required.

## Part 1: K3s server and worker

This provisions two Debian VMs:

- Server: `192.168.56.110`
- Worker: `192.168.56.111`

Run:

```bash
cd p1
vagrant up
```

The server writes its K3s node token to `p1/confs/node-token`; the worker uses that token to join the cluster. Verify the nodes from the server:

```bash
vagrant ssh zbentaleS
sudo kubectl get nodes
```

Destroy the VMs with:

```bash
vagrant destroy -f
```

## Part 2: Kubernetes applications and Ingress

This provisions a K3s server at `192.168.56.110` and deploys:

- `app1`: one replica
- `app2`: three replicas
- `app3`: one replica
- An Ingress routing `app1.com` and `app2.com`; requests without a host are routed to `app3`

Run:

```bash
cd p2
vagrant up
```

Inspect the deployment:

```bash
vagrant ssh zbentaleS
sudo kubectl get pods,services,ingress
```

To test the host-based routes from the host machine, add the following entries to `/etc/hosts`:

```text
192.168.56.110 app1.com app2.com
```

Then open `http://app1.com` or `http://app2.com` in a browser. Remove the VMs with `vagrant destroy -f`.

## Part 3: Argo CD with GitHub

The `p3` script creates a local K3d cluster named `iot-cluster`, installs Argo CD, and applies `p3/confs/argocd-application.yaml`. That Application watches the `manifests` directory in the configured GitHub repository and syncs it to the `dev` namespace.

Run from the repository root:

```bash
cd p3
bash scripts/install.sh
```

The script exposes:

- Argo CD: <https://localhost:8080>
- Argo CD username: `admin`

The script prints the initial admin password after installation. The K3d load balancer also maps port `8888` to the host.

If the Git repository changes, Argo CD automatically prunes removed resources and self-heals drift:

```bash
kubectl -n dev get deployments,services
kubectl -n argocd get applications
```

## Bonus: GitLab-backed Argo CD

The bonus script creates the same K3d cluster if necessary, installs Argo CD and GitLab, creates the `root/iot-bonus-manifests` GitLab project, pushes the bonus manifests to it, and configures Argo CD to sync from GitLab.

Run:

```bash
cd bonus
bash scripts/install.sh
```

The script prints credentials and URLs for:

- Argo CD: <https://localhost:8080>
- GitLab: <http://localhost:8090>
- GitLab repository: `http://localhost:8090/root/iot-bonus-manifests`

The generated GitLab API token is stored locally in `bonus/confs/.gitlab-root-token`. Treat this file as a secret and do not commit it.

Check the bonus deployment with:

```bash
kubectl -n dev-gitlab get deployments,services
kubectl -n argocd get applications
```

## Cleanup

For Vagrant exercises:

```bash
cd p1   # or p2
vagrant destroy -f
```

For K3d exercises:

```bash
k3d cluster delete iot-cluster
```

## Notes

- The provisioning scripts are intended to be run on Linux.
- `p1` and `p2` use the private `192.168.56.0/24` VirtualBox network.
- `p3` and `bonus` share the K3d cluster name `iot-cluster`; delete or reuse the cluster deliberately when switching between them.
- GitLab is configured with HTTP only and reduced resource settings for local development.
