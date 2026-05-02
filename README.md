# server-build

Self-hosted services running on a single-node k3s Kubernetes cluster, with all persistent data on a ZFS RAIDZ2 pool (`tank`).

## Services

| Service | Namespace | NodePort | Domain |
|---------|-----------|----------|--------|
| Cloudflare Tunnel | `cloudflare` | — (hostNetwork) | routes all below |
| Actual Budget (Nathan) | `actual-budget` | 30506 | budget.nphls.com |
| Actual Budget (Cherise) | `actual-budget` | 30507 | budgetc.nphls.com |
| Jellyfin | `jellyfin` | 30896 | jellyfin.nphls.com |
| Homepage | `homepage` | 30300 | — |
| AdGuard Home | `adguardhome` | hostNetwork | — |
| Nextcloud | `nextcloud` | 30808 | nextcloud.nphls.com |
| Nextcloud Collabora | `nextcloud` | 30980 | — |
| Immich | `immich` | 32283 | immich.nphls.com |

## Data Layout

All persistent data lives on the ZFS pool. k8s PVs use `hostPath` pointing directly to existing directories — nothing is ever copied or moved during deployment.

```
/tank/
  photos/immich/          ← Immich upload location (UPLOAD_LOCATION)
  media/movies            ← Jellyfin media (read-only)
  media/tv                ← Jellyfin media (read-only)
  nextcloud/
    db/                   ← Nextcloud MariaDB
    data/                 ← Nextcloud app data
    config/               ← Nextcloud config
  documents/              ← Nextcloud external storage
  users/                  ← Nextcloud external storage
  files/                  ← Nextcloud external storage
  appdata/
    k3s/                  ← k3s server state
    k3s-volumes/          ← local-path-provisioner root
    immich/
      postgres/           ← Immich database (pgvecto-rs pg14)
      ml-cache/           ← Immich ML model cache
    actual-budget/actual-data/
    actual-budget-cherise/actual-data/
    adguardhome/work/
    adguardhome/conf/
    homepage/config/
    jellyfin/config/
    nextcloud/            ← compose file
    secrets.env           ← all secrets (never committed)
```

## Fresh Deployment (new machine)

```bash
# 1. Import ZFS pool (carries all data + secrets.env)
zfs import tank

# 2. Install k3s
sudo bash kube/install.sh

# Fix kubeconfig permissions (required after every k3s restart)
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# 3. Apply storage — delete existing StorageClass first (reclaimPolicy is immutable)
kubectl delete storageclass local-path
kubectl apply -f kube/storage/

# 4. Apply all manifests
kubectl apply -f kube/cloudflare/deployment.yaml
kubectl apply -f kube/actual-budget/namespace.yaml
kubectl apply -f kube/actual-budget/nathan.yaml
kubectl apply -f kube/actual-budget/cherise.yaml
kubectl apply -f kube/jellyfin/jellyfin.yaml
kubectl apply -f kube/homepage/homepage.yaml
kubectl apply -f kube/adguardhome/adguardhome.yaml
kubectl apply -f kube/nextcloud/nextcloud.yaml
kubectl apply -f kube/immich/immich.yaml

# 5. Apply secrets (reads from /tank/appdata/secrets.env)
bash scripts/apply-secrets.sh
```

## Secrets

All credentials live in `/tank/appdata/secrets.env` (travels with the ZFS pool, never committed to git). The template with all keys is at `scripts/secrets.env.template`.

```bash
# Update a credential
nano /tank/appdata/secrets.env
bash scripts/apply-secrets.sh   # idempotent — safe to re-run
```

## Cloudflare Tunnel

The tunnel pod runs with `hostNetwork: true` so it can reach services on `localhost`. Ingress rules are configured in the Cloudflare dashboard and point to NodePorts. When migrating a service from Docker to k3s, update the dashboard rule from the old Docker port to the k3s NodePort.

| Service | Old Docker port | k3s NodePort |
|---------|----------------|--------------|
| Immich | 2283 | 32283 |
| Budget (Nathan) | 5006 | 30506 |
| Budget (Cherise) | 5007 | 30507 |
| Jellyfin | 8096 | 30896 |
| Nextcloud | 8080 | 30808 |

Token is passed via `TUNNEL_TOKEN` environment variable (not as a command-line arg).

## Immich — Postgres Migration

Immich currently runs on **pgvecto-rs pg14** (deprecated). The official recommendation is cloudnative-vectorchord pg16. Migration steps are in `kube/immich/postgres-migration/` — run them when ready, existing data is fully preserved.

## Known Issues / Quirks

**kubeconfig permissions** — k3s writes `/etc/rancher/k3s/k3s.yaml` as root-only. Fix after install (and after reboots if the service restarts):
```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```
To make persistent, a systemd drop-in is at `/etc/systemd/system/k3s.service.d/kubeconfig-mode.conf`.

**StorageClass reclaimPolicy** — the `local-path` StorageClass shipped by k3s defaults to `Delete`. Our version uses `Retain` (safer). The field is immutable so it must be deleted before applying:
```bash
kubectl delete storageclass local-path
kubectl apply -f kube/storage/storage-class.yaml
```

**Nextcloud CronJob** — the cron runs every 5 minutes and k3s doesn't auto-clean completed pods. Remove old ones manually:
```bash
kubectl delete pods -n nextcloud --field-selector=status.phase=Succeeded
```

**secrets.env special characters** — passwords containing `$`, `*`, or other shell metacharacters must be single-quoted in `secrets.env`:
```
NEXTCLOUD_COLLABORA_PASSWORD='p@ss$word*here'
```
