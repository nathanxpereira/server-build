# HomeLab VPN + AdGuard + Dockerized Services Setup

This guide walks you through setting up a home server environment where:

- All devices on your Tailscale VPN use **AdGuard Home** as DNS.
- Internal services (e.g., Immich, Budget app) are exposed via **Nginx reverse proxy**.
- Docker is used for services, including Immich and AdGuard Home.
- The setup allows VPN clients to access services directly via Tailscale IPs, bypassing public Cloudflare routing.
- Troubleshooting tips and diagrams included.

---

## Table of Contents

1. [Prerequisites](#prerequisites)  
2. [Install Docker & Docker Compose](#install-docker--docker-compose)  
3. [Set up AdGuard Home in Docker](#set-up-adguard-home-in-docker)  
4. [Configure Tailscale VPN](#configure-tailscale-vpn)  
5. [Set up Immich in Docker](#set-up-immich-in-docker)  
6. [Configure Nginx as Reverse Proxy](#configure-nginx-as-reverse-proxy)  
7. [DNS Rewrites](#dns-rewrites)  
8. [Testing the Setup](#testing-the-setup)  
9. [Troubleshooting](#troubleshooting)  
10. [Architecture Diagram](#architecture-diagram)  

---

## Prerequisites

- Linux server (Fedora recommended)
- Root or sudo access
- Domain names pointing to your server (Cloudflare or public DNS)
- Tailscale account

---

## Install Docker & Docker Compose

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker --version
docker compose version
```

## Setup AdGuard Home in Docker
1. Create Directories:
```bash
mkdir -p /opt/stacks/adguard/work /opt/stacks/adguard/conf
```
2. Docker Compose file ```docker-compose.yaml```
```yaml
version: "3.9"
services:
  adguardhome:
    image: adguard/adguardhome
    container_name: adguardhome
    restart: unless-stopped
    network_mode: "host"       # Host networking
    volumes:
      - ~/adguard/work:/opt/adguardhome/work
      - ~/adguard/conf:/opt/adguardhome/conf
    environment:
      - TZ=America/Los_Angeles
```
3. Start Adguard to autogenerate the config file
```
docker compose up -d
docker compose down
```
4. Configure web UI ports in ```/opt/stacks/adguard/conf```
```
http:
  address: 
    - 127.0.0.1:3000      # Web UI port
```

## Configure Tailscale VPN
1. Install tailscale. Follow instructions here: https://tailscale.com/kb/1347/installation

2. Enable Adguard as DNS for tailscale clients:
```
sudo tailscale set --accept-dns=true
```

## Configure Nginx as Reverse Proxy
1. Install nginx
```
sudo dnf install -y nginx
sudo systemctl enable --now nginx
```
2. Create a server block
```
server {
    listen 80;
    server_name immich.nphls.com;

    location / {
        proxy_pass http://127.0.0.1:2283/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
    }
}
```
3. Test and restart
```
sudo nginx -t
sudo systemctl restart nginx
```
4. SELinux adjustment (Fedora):
```
sudo setsebool -P httpd_can_network_connect 1
```

## DNS Rewrites in Adguard
1. Adguard Home --> Filters --> DNS Rewrites. 

| Domain           | IP Address / Target                      |
| ---------------- | ---------------------------------------- |
| immich.nphls.com | Tailscale IP of server (100.xxx.xxx.xxx) |
 This ensures VPN clients resolve immich.nphls.com to internal tailscale ip. 

```
[ iPhone / Device ] 
        |
        | (DNS query) 
        v
[ AdGuard Home (DNS, Tailscale IP) ]
        |
        | (HTTP request)
        v
[ Nginx (Reverse Proxy) ] ---> [ Immich Docker Container :2283 ]

AdGuard Web UI -> port 3000
Tailscale VPN ensures traffic goes through server
```

Notes

AdGuard Home continues to handle DNS (port 53).

Nginx proxies HTTP/HTTPS traffic to backend Docker services.

No ports need to be specified in the browser for standard HTTP (80) / HTTPS (443).

Adding new services just requires exposing Docker ports + Nginx server block + optional DNS rewrite.