# ZFS NAS Setup Guide for Fedora

Complete guide for setting up a ZFS storage pool with RAIDZ2 and cache drive on Fedora Linux.

## System Overview

**Hardware:**
- CPU: Intel Ultra 7 265K
- RAM: 32GB
- Storage Drives:
  - 6x 20TB HDDs (for main storage pool)
  - 1x 1TB NVMe SSD (WD Black SN7100 - for ZFS cache)
- HBA Card: SAS9305-16i (must be in IT mode for ZFS)
- OS: Fedora Linux

**Target Configuration:**
- ZFS RAIDZ2 pool (~80TB usable capacity)
- 2-drive fault tolerance
- 1TB SSD as ZFS special vdev for metadata
- Web management via Cockpit

---

## Part 1: Prerequisites and Preparation

### 1.1 Verify HBA Card is in IT Mode

ZFS requires direct disk access, so your HBA must be in IT (Initiator Target) mode, not RAID mode.

```bash
# Check current mode
sudo lspci -v | grep -i sas

# If it shows RAID controller, you'll need to flash to IT mode
# This usually requires downloading firmware from Broadcom/LSI
# Search for "SAS9305-16i IT mode firmware" for instructions
```

**Important:** Flashing firmware will erase any existing RAID configurations. Back up data first.

### 1.2 Install ZFS on Fedora

```bash
# Install ZFS repository
sudo dnf install -y https://zfsonlinux.org/fedora/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm

# Install ZFS kernel module and utilities
sudo dnf install -y zfs

# Load the ZFS kernel module
sudo modprobe zfs

# Enable ZFS to load on boot
sudo systemctl enable zfs-import-cache.service
sudo systemctl enable zfs-import.target
sudo systemctl enable zfs-mount.service
sudo systemctl enable zfs.target
```

### 1.3 Identify Your Drives

```bash
# List all drives
lsblk

# Get detailed info including serial numbers (recommended for identification)
ls -la /dev/disk/by-id/

# Check SMART status of each drive
sudo smartctl -a /dev/sdX  # Replace X with each drive letter
```

**Best Practice:** Use `/dev/disk/by-id/` paths instead of `/dev/sdX` because they're persistent across reboots.

Example output:
```
/dev/disk/by-id/ata-WDC_WD200EDAZ-11F4RA0_1ABC2DEF
/dev/disk/by-id/ata-WDC_WD200EDAZ-11F4RA0_2ABC3DEF
... (etc for all 6 drives)
/dev/disk/by-id/nvme-WD_BLACK_SN7100_1TB_XXXXX
```

---

## Part 2: Creating the ZFS Pool

### 2.1 Create RAIDZ2 Pool with 6 Drives

**Important:** Double-check your drive paths! This will erase all data on these drives.

```bash
# Create the pool named "tank" with RAIDZ2
# Replace the disk IDs with your actual disk-by-id paths
sudo zpool create tank raidz2 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE1 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE2 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE3 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE4 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE5 \
  /dev/disk/by-id/ata-WDC_WD200EDAZ-DRIVE6

# Verify the pool was created
zpool status

# Check pool capacity
zpool list
```

Expected output:
```
NAME   SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP  HEALTH  ALTROOT
tank  109T    XX   109T        -         -     0%     0%  1.00x  ONLINE  -
```

You'll get approximately 80TB usable space (4 drives worth, 2 for parity).

### 2.2 Add the 1TB NVMe as Special Vdev

The special vdev stores all metadata and small files on the fast SSD, dramatically improving performance.

```bash
# Add the NVMe as a special vdev
sudo zpool add tank special \
  /dev/disk/by-id/nvme-WD_BLACK_SN7100_1TB_XXXXX

# Verify it was added
zpool status tank
```

Output should show:
```
  pool: tank
 state: ONLINE
  scan: none requested
config:

    NAME                          STATE     READ WRITE CKSUM
    tank                          ONLINE       0     0     0
      raidz2-0                    ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE1  ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE2  ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE3  ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE4  ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE5  ONLINE       0     0     0
        ata-WDC_WD200EDAZ-DRIVE6  ONLINE       0     0     0
    special
        nvme-WD_BLACK_SN7100_1TB  ONLINE       0     0     0

errors: No known data errors
```

**Critical Warning:** If your special vdev fails, your entire pool is lost. Consider adding a second identical SSD mirrored with the first for redundancy:

```bash
# If you want redundancy (recommended for special vdev):
# sudo zpool add tank special mirror \
#   /dev/disk/by-id/nvme-WD_BLACK_SN7100_1TB_XXXXX \
#   /dev/disk/by-id/nvme-ANOTHER_1TB_SSD_XXXXX
```

### 2.3 Optimize ZFS Settings

```bash
# Enable LZ4 compression (fast, great compression ratio)
sudo zfs set compression=lz4 tank

# Set reasonable recordsize for media files (1M is good for video)
sudo zfs set recordsize=1M tank

# Enable automatic snapshots visibility
sudo zfs set snapdir=visible tank

# Disable access time updates (improves performance)
sudo zfs set atime=off tank

# Set the mount point
sudo zfs set mountpoint=/mnt/tank tank

# Verify settings
zfs get all tank | grep -E "compression|recordsize|atime|mountpoint"
```

### 2.4 Create Datasets for Organization

```bash
# Create datasets for different media types
sudo zfs create tank/media
sudo zfs create tank/media/movies
sudo zfs create tank/media/tv
sudo zfs create tank/media/music
sudo zfs create tank/media/photos

# Create dataset for Plex/Jellyfin metadata (benefits from special vdev)
sudo zfs create tank/plex-metadata
sudo zfs set recordsize=128K tank/plex-metadata  # Better for small files

# Create dataset for transcoding (temporary files)
sudo zfs create tank/transcode
sudo zfs set sync=disabled tank/transcode  # Faster for temp files
sudo zfs set recordsize=1M tank/transcode

# Set permissions
sudo chown -R $USER:$USER /mnt/tank/media
sudo chown -R $USER:$USER /mnt/tank/transcode
```

---

## Part 3: Setting Up Cockpit for Web Management

### 3.1 Install Cockpit

```bash
# Install Cockpit and storage modules
sudo dnf install -y cockpit cockpit-storaged cockpit-podman

# Enable and start Cockpit
sudo systemctl enable --now cockpit.socket

# Allow through firewall
sudo firewall-cmd --add-service=cockpit --permanent
sudo firewall-cmd --reload
```

### 3.2 Install ZFS Management for Cockpit

Cockpit doesn't have native ZFS support, but we can use cockpit-navigator for file management:

```bash
# Install cockpit-navigator for file browsing
sudo dnf install -y cockpit-navigator

# Alternatively, install cockpit-file-sharing for Samba management
sudo dnf install -y cockpit-file-sharing
```

### 3.3 Access Cockpit

```bash
# Find your machine's IP address
ip addr show | grep inet

# Access Cockpit in your browser
# https://localhost:9090
# or
# https://YOUR_IP_ADDRESS:9090
```

Login with your Fedora username and password.

**Cockpit Features:**
- Dashboard: System resource monitoring (CPU, RAM, disk, network)
- Storage: View disk usage, SMART status
- Podman Containers: Manage Docker containers
- Services: Start/stop system services
- Terminal: Built-in web terminal for ZFS commands
- Logs: View system logs

### 3.4 Running Media Server in Docker via Cockpit

#### Install Jellyfin via Cockpit-Podman:

1. Navigate to **Podman Containers** in Cockpit
2. Click **Create Container**
3. Use these settings:

**Jellyfin Container:**
```yaml
Name: jellyfin
Image: docker.io/jellyfin/jellyfin:latest
Port Mappings:
  - 8096:8096 (Web UI)
  - 8920:8920 (HTTPS)
Volume Mounts:
  - /mnt/tank/media:/media
  - /mnt/tank/plex-metadata:/config
  - /mnt/tank/transcode:/cache
Environment Variables:
  - PUID=1000 (your user ID, check with 'id' command)
  - PGID=1000 (your group ID)
Restart Policy: always
```

**CLI Alternative (if you prefer terminal):**

```bash
# Create Jellyfin container
podman run -d \
  --name jellyfin \
  --restart=always \
  -p 8096:8096 \
  -p 8920:8920 \
  -v /mnt/tank/media:/media:ro \
  -v /mnt/tank/plex-metadata:/config \
  -v /mnt/tank/transcode:/cache \
  -e PUID=1000 \
  -e PGID=1000 \
  docker.io/jellyfin/jellyfin:latest

# Enable GPU transcoding (if using Quadro M6000)
# Add these flags to the podman run command:
# --device=/dev/dri:/dev/dri \
# --group-add video

# Access Jellyfin at http://localhost:8096
```

#### Plex Alternative:

```bash
podman run -d \
  --name plex \
  --restart=always \
  --network=host \
  -v /mnt/tank/media:/media:ro \
  -v /mnt/tank/plex-metadata:/config \
  -v /mnt/tank/transcode:/transcode \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=America/New_York \
  docker.io/plexinc/pms-docker:latest
```

---

## Part 4: Network Sharing - Making Your NAS Accessible

Now that your storage is set up, let's make it accessible to other devices on your network.

### 4.1 Overview of Sharing Options

| Protocol | Best For | Pros | Cons |
|----------|----------|------|------|
| **Samba/SMB** | Windows, macOS, mixed networks | Universal compatibility, easy setup | Slightly slower than NFS |
| **NFS** | Linux-to-Linux | Best performance for Unix/Linux | Limited Windows support |
| **WebDAV** | Remote access, web browsers | No client needed, HTTP-based | Slower, less feature-rich |

**Recommendation:** Use **Samba + NFS** together for maximum compatibility and performance.

---

### 4.2 Setting Up Samba (SMB/CIFS)

Samba provides Windows-compatible file sharing that works with all major operating systems.

#### Install Samba:

```bash
# Install Samba packages
sudo dnf install -y samba samba-client samba-common

# Start and enable services
sudo systemctl enable --now smb nmb

# Configure firewall
sudo firewall-cmd --permanent --add-service=samba
sudo firewall-cmd --reload
```

#### Create Samba Users:

```bash
# Add your user to Samba (must be existing Linux user)
sudo smbpasswd -a $USER
# Enter password when prompted (can be different from Linux password)

# Optional: Create a dedicated NAS user
sudo useradd -M -s /usr/sbin/nologin nasuser
sudo smbpasswd -a nasuser
```

#### Configure Samba Shares:

```bash
# Backup original config
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

# Edit Samba configuration
sudo nano /etc/samba/smb.conf
```

Add this to the **end** of the file:

```ini
#======================= Share Definitions =======================

[Media]
    comment = Main Media Storage
    path = /mnt/tank/media
    browseable = yes
    read only = no
    valid users = your-username nasuser
    create mask = 0664
    directory mask = 0775
    force user = your-username
    force group = your-username

[Movies]
    comment = Movie Collection
    path = /mnt/tank/media/movies
    browseable = yes
    read only = no
    valid users = your-username nasuser
    create mask = 0664
    directory mask = 0775

[TV]
    comment = TV Shows
    path = /mnt/tank/media/tv
    browseable = yes
    read only = no
    valid users = your-username nasuser
    create mask = 0664
    directory mask = 0775

[Music]
    comment = Music Library
    path = /mnt/tank/media/music
    browseable = yes
    read only = no
    valid users = your-username nasuser
    create mask = 0664
    directory mask = 0775

[Photos]
    comment = Photo Collection
    path = /mnt/tank/media/photos
    browseable = yes
    read only = no
    valid users = your-username nasuser
    create mask = 0664
    directory mask = 0775

[Photos-ReadOnly]
    comment = Photos (Read-Only Access)
    path = /mnt/tank/media/photos
    browseable = yes
    read only = yes
    guest ok = no
    valid users = @family
```

#### Performance Tuning for Samba:

Add these optimizations to the `[global]` section in `/etc/samba/smb.conf`:

```ini
[global]
    # Network optimization
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=524288 SO_SNDBUF=524288
    
    # Performance settings
    read raw = yes
    write raw = yes
    max xmit = 65535
    dead time = 15
    getwd cache = yes
    
    # Large file support
    min receivefile size = 16384
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384
    
    # Security (restrict to local network)
    hosts allow = 192.168.1.0/24 127.0.0.1
    hosts deny = 0.0.0.0/0
    
    # Logging
    log level = 1
    max log size = 1000
```

**Important:** Replace `192.168.1.0/24` with your actual network subnet.

#### Test and Restart Samba:

```bash
# Test configuration for errors
testparm

# Restart Samba services
sudo systemctl restart smb nmb

# Verify services are running
sudo systemctl status smb nmb

# Check current connections
sudo smbstatus
```

#### Configure SELinux (if enabled):

```bash
# Allow Samba to share ZFS directories
sudo setsebool -P samba_export_all_rw on
sudo setsebool -P samba_export_all_ro on

# If you need more specific control:
sudo semanage fcontext -a -t samba_share_t "/mnt/tank/media(/.*)?"
sudo restorecon -Rv /mnt/tank/media
```

---

### 4.3 Setting Up NFS (Network File System)

NFS provides high-performance file sharing, ideal for Linux clients.

#### Install NFS Server:

```bash
# Install NFS utilities
sudo dnf install -y nfs-utils

# Enable and start NFS server
sudo systemctl enable --now nfs-server

# Configure firewall
sudo firewall-cmd --permanent --add-service=nfs
sudo firewall-cmd --permanent --add-service=mountd
sudo firewall-cmd --permanent --add-service=rpc-bind
sudo firewall-cmd --reload
```

#### Configure NFS Exports:

```bash
# Edit exports file
sudo nano /etc/exports
```

Add your shares (replace `192.168.1.0/24` with your network):

```bash
# Main media directory
/mnt/tank/media          192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)

# Individual media directories
/mnt/tank/media/movies   192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/tv       192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/music    192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/photos   192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)

# Read-only share example
/mnt/tank/media/photos   192.168.1.0/24(ro,sync,no_subtree_check)
```

**NFS Export Options Explained:**
- `rw` = Read-write access
- `ro` = Read-only access
- `sync` = Changes written to disk immediately (safer, slower)
- `async` = Changes written to cache first (faster, less safe)
- `no_subtree_check` = Improves reliability
- `no_root_squash` = Allow root on client to access as root (use carefully)
- `all_squash` = Map all users to anonymous user (more secure)

#### Apply NFS Configuration:

```bash
# Export all directories in /etc/exports
sudo exportfs -arv

# Verify exports
sudo exportfs -v

# Check NFS status
sudo systemctl status nfs-server

# View active NFS connections
sudo showmount -a
```

#### NFS Performance Tuning:

```bash
# Edit NFS configuration
sudo nano /etc/nfs.conf
```

Add under `[nfsd]` section:
```ini
[nfsd]
threads=16
udp=n
tcp=y
vers2=n
vers3=y
vers4=y
```

```bash
# Restart NFS
sudo systemctl restart nfs-server
```

---

### 4.4 Using Cockpit for Easy Share Management

Cockpit provides a web-based GUI for managing file shares.

#### Install Cockpit File Sharing:

```bash
# Install file sharing plugin
sudo dnf install -y cockpit-file-sharing

# Restart Cockpit
sudo systemctl restart cockpit.socket
```

#### Manage Shares via Cockpit:

1. Access Cockpit: `https://YOUR-NAS-IP:9090`
2. Navigate to **Storage** or **File Sharing** (if plugin installed)
3. Browse to your ZFS datasets
4. Click **Share** or **Create Share**
5. Configure:
   - Share name
   - Path
   - Protocol (Samba/NFS)
   - Permissions
   - Allowed users/networks
6. Click **Create**

The GUI handles all the configuration file editing for you.

---

### 4.5 Accessing Your NAS from Client Devices

#### Windows Clients:

**Method 1: Map Network Drive**
1. Open File Explorer
2. Right-click **This PC** → **Map network drive**
3. Choose drive letter (e.g., Z:)
4. Enter path: `\\YOUR-NAS-IP\Media`
5. Check **Reconnect at sign-in**
6. Click **Finish**
7. Enter username and password when prompted

**Method 2: Quick Access**
- Open File Explorer
- In address bar, type: `\\YOUR-NAS-IP\Media`
- Press Enter

**Find Your NAS IP:**
```bash
# On your NAS, run:
hostname -I | awk '{print $1}'
```

#### macOS Clients:

**Method 1: Finder**
1. Open Finder
2. Press `⌘K` (or Go → Connect to Server)
3. Enter: `smb://YOUR-NAS-IP/Media`
4. Click **Connect**
5. Enter credentials
6. Choose volumes to mount

**Method 2: Mount at Login**
1. System Preferences → Users & Groups
2. Select your user → Login Items
3. Click **+** and add the network volume

#### Linux Clients (Samba):

**GUI Method:**
1. Open file manager
2. Navigate to **Network** or **Other Locations**
3. Enter: `smb://YOUR-NAS-IP/Media`
4. Enter credentials

**Command Line Method:**
```bash
# Install CIFS utilities
sudo dnf install -y cifs-utils  # Fedora/RHEL
sudo apt install -y cifs-utils   # Ubuntu/Debian

# Create mount point
sudo mkdir -p /mnt/nas

# Mount temporarily
sudo mount -t cifs //YOUR-NAS-IP/Media /mnt/nas -o username=your-username

# Mount permanently (add to /etc/fstab)
# Create credentials file first
sudo nano /root/.nascredentials
```

Add to credentials file:
```
username=your-username
password=your-password
```

```bash
# Secure the credentials file
sudo chmod 600 /root/.nascredentials

# Add to /etc/fstab
echo "//YOUR-NAS-IP/Media /mnt/nas cifs credentials=/root/.nascredentials,uid=1000,gid=1000 0 0" | sudo tee -a /etc/fstab

# Mount all fstab entries
sudo mount -a
```

#### Linux Clients (NFS):

**Command Line Method:**
```bash
# Create mount point
sudo mkdir -p /mnt/nas

# Mount temporarily
sudo mount -t nfs YOUR-NAS-IP:/mnt/tank/media /mnt/nas

# Mount permanently (add to /etc/fstab)
echo "YOUR-NAS-IP:/mnt/tank/media /mnt/nas nfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab

# Mount all fstab entries
sudo mount -a

# Verify mount
df -h | grep nas
```

#### Android/iOS Mobile Devices:

**Android:**
- Install apps like: **Solid Explorer**, **FX File Explorer**, **ES File Explorer**
- Add network storage → SMB/CIFS
- Enter: `YOUR-NAS-IP`, share name, credentials

**iOS:**
- Use built-in **Files** app
- Tap **...** → **Connect to Server**
- Enter: `smb://YOUR-NAS-IP/Media`
- Or use apps like: **FileBrowser**, **Documents by Readdle**

---

### 4.6 Advanced Configuration

#### Create Multiple User Access Levels:

```bash
# Create user groups
sudo groupadd family
sudo groupadd readonly

# Add users to groups
sudo usermod -aG family your-username
sudo usermod -aG readonly guest-user

# Create dedicated shares with group permissions
sudo nano /etc/samba/smb.conf
```

Add:
```ini
[Family-Photos]
    comment = Family Photos
    path = /mnt/tank/media/photos/family
    valid users = @family
    read only = no
    create mask = 0664
    directory mask = 0775

[Public-ReadOnly]
    comment = Public Read-Only Content
    path = /mnt/tank/media/public
    valid users = @readonly @family
    read only = yes
    guest ok = yes
```

#### Enable Recycle Bin (Trash):

Prevent accidental deletions by enabling a recycle bin.

```bash
# Edit Samba config
sudo nano /etc/samba/smb.conf
```

Add to each share:
```ini
[Media]
    # ... existing config ...
    vfs objects = recycle
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
    recycle:maxsize = 0
```

Create recycle directories:
```bash
sudo mkdir -p /mnt/tank/media/.recycle
sudo chmod 1777 /mnt/tank/media/.recycle
```

#### Enable Audit Logging:

Track who accesses what files.

```bash
# Add to Samba share config
[Media]
    # ... existing config ...
    vfs objects = full_audit
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = open opendir read write
    full_audit:failure = connect
    full_audit:facility = local5
    full_audit:priority = notice
```

View logs:
```bash
sudo tail -f /var/log/samba/log.smbd
```

#### Time Machine Support (macOS Backups):

```bash
# Install Avahi for network discovery
sudo dnf install -y avahi

# Add to Samba config
[TimeMachine]
    comment = Time Machine Backup
    path = /mnt/tank/timemachine
    valid users = your-username
    read only = no
    create mask = 0600
    directory mask = 0700
    fruit:time machine = yes
    fruit:time machine max size = 1T
    vfs objects = catia fruit streams_xattr

# Create directory
sudo mkdir -p /mnt/tank/timemachine
sudo chown your-username:your-username /mnt/tank/timemachine
```

---

### 4.7 Security Best Practices

#### 1. Restrict Access to Local Network Only:

In `/etc/samba/smb.conf` under `[global]`:
```ini
hosts allow = 192.168.1.0/24 127.0.0.1
hosts deny = 0.0.0.0/0
```

In `/etc/exports` for NFS:
```bash
/mnt/tank/media 192.168.1.100(rw,sync) 192.168.1.101(ro,sync)
# Only specific IPs instead of entire subnet
```

#### 2. Use Strong Passwords:

```bash
# Set strong Samba password
sudo smbpasswd -a username
# Use passwords with 12+ characters, mixed case, numbers, symbols
```

#### 3. Disable Guest Access:

In `/etc/samba/smb.conf` under `[global]`:
```ini
map to guest = never
guest ok = no
```

#### 4. Enable Encryption (SMB3):

In `/etc/samba/smb.conf` under `[global]`:
```ini
server min protocol = SMB3
smb encrypt = required
```

#### 5. Regular Security Audits:

```bash
# Check who's connected
sudo smbstatus

# View Samba logs
sudo tail -f /var/log/samba/log.smbd

# Check NFS connections
sudo showmount -a

# Monitor authentication attempts
sudo journalctl -u smb -f
```

---

### 4.8 Monitoring and Troubleshooting Network Shares

#### Check Samba Status:

```bash
# Overall status
sudo systemctl status smb nmb

# Active connections
sudo smbstatus

# List all shares
sudo smbclient -L localhost -U%

# Test config
testparm -s
```

#### Check NFS Status:

```bash
# NFS server status
sudo systemctl status nfs-server

# Active exports
sudo exportfs -v

# Current mounts
sudo showmount -a

# NFS statistics
nfsstat -s
```

#### Common Issues and Solutions:

**Problem: Can't connect to Samba share**
```bash
# Check firewall
sudo firewall-cmd --list-all | grep samba

# Verify service running
sudo systemctl status smb nmb

# Check SELinux
sudo getsebool -a | grep samba
sudo setsebool -P samba_export_all_rw on

# Test from server itself
smbclient //localhost/Media -U your-username
```

**Problem: NFS mount permission denied**
```bash
# Re-export shares
sudo exportfs -ra

# Check permissions
ls -la /mnt/tank/media

# Verify client IP is allowed
sudo exportfs -v

# Check logs
sudo journalctl -u nfs-server -n 50
```

**Problem: Slow transfer speeds**
```bash
# Test network speed
iperf3 -s  # on NAS
iperf3 -c YOUR-NAS-IP  # on client

# Check for 1Gbps or 10Gbps link
ethtool eth0 | grep Speed

# Monitor network during transfer
sudo iftop -i eth0

# Check if jumbo frames enabled (9000 MTU)
ip link show eth0
```

**Problem: Files disappear or wrong owner**
```bash
# Check Samba user mapping
sudo pdbedit -L -v

# Fix ownership
sudo chown -R your-username:your-username /mnt/tank/media

# Check force user/group in smb.conf
testparm -v | grep "force user"
```

#### Network Share Performance Testing:

```bash
# Install tools
sudo dnf install -y iperf3 fio

# Test write speed to share
dd if=/dev/zero of=/mnt/nas/testfile bs=1M count=10000

# Test read speed
dd if=/mnt/nas/testfile of=/dev/null bs=1M

# Clean up
rm /mnt/nas/testfile
```

---

### 4.9 Automated Share Configuration Script

Save time with this automated setup script:

```bash
#!/bin/bash
# NAS Network Share Setup Script

set -e

echo "=== NAS Network Share Setup ==="
echo ""

# Get network information
HOSTNAME=$(hostname)
IP_ADDR=$(hostname -I | awk '{print $1}')
NETWORK_SUBNET=$(echo $IP_ADDR | cut -d. -f1-3).0/24

echo "Hostname: $HOSTNAME"
echo "IP Address: $IP_ADDR"
echo "Network: $NETWORK_SUBNET"
echo ""

# Install packages
echo "Installing required packages..."
sudo dnf install -y samba samba-client nfs-utils cockpit-file-sharing avahi

# Configure Samba
echo "Configuring Samba..."
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

# Add performance settings to Samba
sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

# Performance Optimizations
[global]
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=524288 SO_SNDBUF=524288
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   getwd cache = yes
   use sendfile = yes
   hosts allow = $NETWORK_SUBNET 127.0.0.1
   hosts deny = 0.0.0.0/0

# Media Shares
[Media]
   comment = Media Storage
   path = /mnt/tank/media
   browseable = yes
   read only = no
   valid users = $USER
   create mask = 0664
   directory mask = 0775
   force user = $USER

[Movies]
   comment = Movies
   path = /mnt/tank/media/movies
   browseable = yes
   read only = no
   valid users = $USER

[TV]
   comment = TV Shows
   path = /mnt/tank/media/tv
   browseable = yes
   read only = no
   valid users = $USER

[Music]
   comment = Music
   path = /mnt/tank/media/music
   browseable = yes
   read only = no
   valid users = $USER

[Photos]
   comment = Photos
   path = /mnt/tank/media/photos
   browseable = yes
   read only = no
   valid users = $USER
EOF

# Configure NFS
echo "Configuring NFS..."
sudo tee /etc/exports > /dev/null <<EOF
/mnt/tank/media $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/movies $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/tv $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/music $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank/media/photos $NETWORK_SUBNET(rw,sync,no_subtree_check,no_root_squash)
EOF

# Configure SELinux
echo "Configuring SELinux..."
sudo setsebool -P samba_export_all_rw on 2>/dev/null || true

# Configure firewall
echo "Configuring firewall..."
sudo firewall-cmd --permanent --add-service=samba
sudo firewall-cmd --permanent --add-service=nfs
sudo firewall-cmd --permanent --add-service=mountd
sudo firewall-cmd --permanent --add-service=rpc-bind
sudo firewall-cmd --reload

# Start services
echo "Starting services..."
sudo systemctl enable --now smb nmb nfs-server avahi-daemon
sudo exportfs -arv

# Test configuration
echo ""
echo "Testing configuration..."
testparm -s

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "Access your NAS from other devices:"
echo "  Windows/macOS (Samba): \\\\$IP_ADDR\\Media"
echo "  Linux (NFS): $IP_ADDR:/mnt/tank/media"
echo "  Web Interface: https://$IP_ADDR:9090"
echo ""
echo "Don't forget to set Samba password:"
echo "  sudo smbpasswd -a $USER"
echo ""
```

Save as `setup-nas-shares.sh`, make executable, and run:
```bash
chmod +x setup-nas-shares.sh
./setup-nas-shares.sh
```

---

### 4.10 Quick Reference - Network Sharing

**Common Commands:**

```bash
# Samba
sudo systemctl restart smb nmb          # Restart Samba
sudo smbstatus                          # Show connections
testparm                                # Test config
sudo smbpasswd -a username              # Add/change user password
sudo pdbedit -L                         # List Samba users

# NFS
sudo systemctl restart nfs-server       # Restart NFS
sudo exportfs -arv                      # Re-export shares
sudo showmount -a                       # Show mounted clients
sudo showmount -e localhost             # List available exports

# Firewall
sudo firewall-cmd --list-all            # Show firewall rules
sudo firewall-cmd --reload              # Reload firewall

# SELinux
sudo getsebool -a | grep samba          # Check Samba booleans
sudo getsebool -a | grep nfs            # Check NFS booleans

# Monitoring
sudo tail -f /var/log/samba/log.smbd    # Samba logs
sudo journalctl -u nfs-server -f        # NFS logs
```

**Connection Strings:**

```
Windows/macOS: \\YOUR-NAS-IP\Media
Linux (Samba): smb://YOUR-NAS-IP/Media
Linux (NFS): YOUR-NAS-IP:/mnt/tank/media
Web Browser: http://YOUR-NAS-IP (if WebDAV configured)
```

---

## Part 5: Maintenance Best Practices

### 4.1 Regular Scrubs (CRITICAL)

Scrubs check data integrity and repair any corruption automatically.

```bash
# Run a scrub manually
sudo zfs scrub tank

# Check scrub status
zpool status

# Stop a scrub if needed
sudo zfs scrub -s tank
```

**Automate Monthly Scrubs:**

```bash
# Create a systemd timer for monthly scrubs
sudo nano /etc/systemd/system/zfs-scrub.service
```

Add this content:
```ini
[Unit]
Description=ZFS scrub on tank pool
After=zfs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/zfs scrub tank
```

```bash
# Create the timer
sudo nano /etc/systemd/system/zfs-scrub.timer
```

Add this content:
```ini
[Unit]
Description=Monthly ZFS scrub

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
# Enable the timer
sudo systemctl daemon-reload
sudo systemctl enable --now zfs-scrub.timer

# Verify it's scheduled
systemctl list-timers | grep zfs-scrub
```

### 4.2 SMART Monitoring

Monitor drive health to catch failures early.

```bash
# Install smartmontools
sudo dnf install -y smartmontools

# Enable the daemon
sudo systemctl enable --now smartd

# Check a drive's health
sudo smartctl -a /dev/sda

# Run short test
sudo smartctl -t short /dev/sda

# Check test results after a few minutes
sudo smartctl -l selftest /dev/sda
```

**Monitor These SMART Attributes:**
- `Reallocated_Sector_Ct` - Should be 0, increasing = failing drive
- `Current_Pending_Sector` - Should be 0
- `Offline_Uncorrectable` - Should be 0
- `Temperature_Celsius` - Keep below 50°C

**Setup Email Alerts:**

Edit `/etc/smartd.conf`:
```bash
sudo nano /etc/smartd.conf
```

Add line:
```
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -m your-email@example.com
```

Restart smartd:
```bash
sudo systemctl restart smartd
```

### 4.3 Snapshot Strategy

Snapshots allow point-in-time recovery from accidental deletions or corruption.

```bash
# Create a manual snapshot
sudo zfs snapshot tank/media@backup-$(date +%Y-%m-%d)

# List snapshots
zfs list -t snapshot

# Restore a file from snapshot
# Snapshots are in .zfs/snapshot/ directory
ls /mnt/tank/media/.zfs/snapshot/

# Roll back entire dataset to snapshot (DESTRUCTIVE!)
# sudo zfs rollback tank/media@backup-2025-11-01

# Delete old snapshots
sudo zfs destroy tank/media@backup-2025-11-01
```

**Automated Snapshots with Sanoid:**

```bash
# Install sanoid for automated snapshots
sudo dnf install -y sanoid

# Configure sanoid
sudo nano /etc/sanoid/sanoid.conf
```

Add:
```ini
[tank/media]
	use_template = production
	recursive = yes

[template_production]
	frequently = 0
	hourly = 24
	daily = 7
	weekly = 4
	monthly = 6
	yearly = 0
	autosnap = yes
	autoprune = yes
```

```bash
# Enable sanoid timer
sudo systemctl enable --now sanoid.timer

# Run manually to test
sudo sanoid --take-snapshots
```

### 4.4 Pool Health Monitoring

**Daily Checks via Script:**

Create `/usr/local/bin/zfs-health-check.sh`:

```bash
#!/bin/bash
# ZFS Health Check Script

POOL="tank"
EMAIL="your-email@example.com"

# Get pool status
STATUS=$(zpool status $POOL)

# Check for errors
ERRORS=$(echo "$STATUS" | grep -E "DEGRADED|FAULTED|UNAVAIL|errors:")

if [ ! -z "$ERRORS" ]; then
    echo "$STATUS" | mail -s "ZFS Pool Alert: $POOL has issues!" $EMAIL
fi

# Check pool capacity
CAPACITY=$(zpool list -H -o capacity $POOL | sed 's/%//')
if [ $CAPACITY -gt 80 ]; then
    echo "Pool $POOL is at ${CAPACITY}% capacity" | mail -s "ZFS Pool Alert: High Capacity" $EMAIL
fi

# Check for scrub errors
SCRUB_ERRORS=$(zpool status $POOL | grep "with 0 errors" | wc -l)
if [ $SCRUB_ERRORS -eq 0 ]; then
    echo "$STATUS" | mail -s "ZFS Pool Alert: Scrub found errors" $EMAIL
fi
```

```bash
# Make executable
sudo chmod +x /usr/local/bin/zfs-health-check.sh

# Add to daily cron
echo "0 8 * * * /usr/local/bin/zfs-health-check.sh" | sudo tee -a /etc/crontab
```

### 4.5 Capacity Management

**Keep pool below 80% full for optimal performance.**

```bash
# Check current usage
zfs list

# Check per-dataset usage
zfs list -o name,used,avail,refer,mountpoint

# Find largest directories
sudo du -h --max-depth=1 /mnt/tank/media | sort -hr | head -20

# Clean up old transcoding files
sudo rm -rf /mnt/tank/transcode/*
```

### 4.6 Backup Strategy (3-2-1 Rule)

**3 copies, 2 different media, 1 offsite**

**Option 1: External Drive Backup**
```bash
# Backup to external USB drive
sudo rsync -avh --progress /mnt/tank/media/photos /mnt/external-backup/

# Or use ZFS send/receive for exact copy
sudo zfs snapshot tank/media/photos@backup
sudo zfs send tank/media/photos@backup | sudo zfs receive backup-pool/photos
```

**Option 2: Cloud Backup (Rclone)**
```bash
# Install rclone
sudo dnf install -y rclone

# Configure cloud provider (Backblaze B2, Wasabi, etc.)
rclone config

# Sync photos to cloud (irreplaceable data)
rclone sync /mnt/tank/media/photos remote:bucket-name/photos -P
```

**Option 3: Second NAS (ZFS Send/Receive)**
```bash
# Send incremental snapshot to another machine
sudo zfs send -i tank/media@old tank/media@new | \
  ssh user@backup-nas "zfs receive backup-pool/media"
```

### 4.7 System Updates

```bash
# Update system regularly
sudo dnf update -y

# Update ZFS (handled by dnf update, but verify)
sudo dnf update zfs

# After kernel updates, rebuild ZFS modules
sudo dkms autoinstall

# Reboot after major updates
sudo reboot
```

### 4.8 Temperature Monitoring

```bash
# Install lm_sensors for system temps
sudo dnf install -y lm_sensors
sudo sensors-detect --auto

# Check temps
sensors

# Monitor drive temperatures
for drive in /dev/sd{a..f}; do
  echo "$drive: $(sudo smartctl -A $drive | grep Temperature_Celsius | awk '{print $10}')°C"
done
```

**Ideal Temperatures:**
- HDDs: 35-45°C (max 50°C)
- NVMe SSD: 40-70°C (throttles at 80°C+)

---

## Part 5: Quick Reference Commands

### Essential ZFS Commands

```bash
# Pool status and health
zpool status
zpool list

# Dataset usage
zfs list
zfs list -o name,used,avail,refer,mountpoint

# Start a scrub
sudo zfs scrub tank

# Create snapshot
sudo zfs snapshot tank/media@name

# List snapshots
zfs list -t snapshot

# Check ZFS ARC (RAM cache) usage
cat /proc/spl/kstat/zfs/arcstats

# Export pool (safely disconnect)
sudo zpool export tank

# Import pool
sudo zpool import tank

# Replace a failed drive
sudo zpool replace tank /dev/disk/by-id/OLD-DRIVE /dev/disk/by-id/NEW-DRIVE

# Check fragmentation
zpool list -o name,frag

# Defragment (rewrite data)
sudo zfs send tank/media@snapshot | sudo zfs receive tank/media-new
```

### Troubleshooting Commands

```bash
# Check for pool errors
zpool status -v

# Clear error counters (after fixing issues)
sudo zpool clear tank

# Check ZFS events log
zpool events

# Monitor I/O in real-time
zpool iostat -v 2

# Check if drives are being detected
ls /dev/disk/by-id/ | grep -v part
```

---

## Part 6: Monthly Maintenance Checklist

### Tasks to Perform Monthly:

- [ ] **Check `zpool status`** - Look for errors or degraded drives
- [ ] **Review SMART data** - Check all 6 HDDs and NVMe for errors
- [ ] **Verify scrub completed** - Should run automatically monthly
- [ ] **Check pool capacity** - Ensure below 80% full
- [ ] **Review system logs** - `journalctl -p err -b`
- [ ] **Check drive temperatures** - All drives should be cool
- [ ] **Test backup restore** - Verify you can actually recover files
- [ ] **Clean up old snapshots** - Remove unnecessary old snapshots
- [ ] **Update system** - `sudo dnf update`
- [ ] **Check Docker containers** - Ensure Jellyfin/Plex running properly

### Quarterly Tasks:

- [ ] **Run extended SMART test** on all drives
- [ ] **Review storage usage trends** - Plan for capacity expansion
- [ ] **Test UPS** if installed
- [ ] **Verify offsite backups** are current

### Annual Tasks:

- [ ] **Review and update documentation**
- [ ] **Consider drive replacement** if any show signs of wear
- [ ] **Audit user access and permissions**
- [ ] **Review and test disaster recovery plan**

---

## Part 7: Warning Signs - Act Immediately If You See:

### Critical Issues:

1. **ZFS Checksum Errors**
   ```bash
   zpool status
   # Look for: "with X errors"
   ```
   - Action: Investigate immediately, may indicate failing drive or corruption

2. **Pool Shows DEGRADED**
   - Action: Check which drive failed, replace ASAP
   - With RAIDZ2, you can lose 2 drives safely

3. **Increasing Reallocated Sectors in SMART**
   ```bash
   sudo smartctl -a /dev/sdX | grep Reallocated_Sector_Ct
   ```
   - Action: If count is increasing, plan drive replacement

4. **Pool >90% Full**
   - Action: Free up space immediately or add more drives
   - Performance severely degraded above 80%

5. **High Drive Temperatures (>50°C sustained)**
   - Action: Improve cooling, check case fans

6. **Special Vdev Failure**
   - **THIS IS CATASTROPHIC** - entire pool is lost
   - Action: Keep special vdev healthy, consider mirrored setup

---

## Part 8: Disaster Recovery

### If a Drive Fails:

```bash
# Check which drive failed
zpool status tank

# Order replacement drive (same size or larger)

# Once new drive arrives, replace failed drive physically

# Replace in ZFS pool
sudo zpool replace tank /dev/disk/by-id/FAILED-DRIVE /dev/disk/by-id/NEW-DRIVE

# Monitor resilver (rebuild) progress
watch zpool status

# Resilver will take many hours for 20TB drives
```

### If Pool Won't Import:

```bash
# Try importing with force
sudo zpool import -f tank

# If that fails, try read-only mode
sudo zpool import -o readonly=on tank

# Last resort: attempt recovery
sudo zpool import -F tank
```

### If You Lose the Special Vdev:

**There is no recovery.** Your entire pool is lost. This is why mirroring the special vdev is recommended for critical data.

---

## Part 9: Additional Resources

### Documentation:
- ZFS on Linux: https://openzfs.github.io/openzfs-docs/
- Fedora ZFS Guide: https://docs.fedoraproject.org/en-US/quick-docs/
- Cockpit Documentation: https://cockpit-project.org/guide/latest/

### Useful Tools:
- **zfs-auto-snapshot**: Automated snapshot management
- **sanoid**: Advanced snapshot management with pruning
- **syncoid**: Efficient ZFS replication
- **smartmontools**: Drive health monitoring
- **rclone**: Cloud backup tool

### Community Support:
- r/zfs on Reddit
- r/homelab on Reddit
- r/DataHoarder on Reddit
- Fedora Forums

---

## Conclusion

You now have:
- ✅ 80TB of reliable storage with 2-drive fault tolerance
- ✅ Fast metadata access via NVMe special vdev
- ✅ Web-based management through Cockpit
- ✅ Docker-based media server
- ✅ Automated health monitoring and scrubs
- ✅ Comprehensive maintenance plan

**Remember:** The three most important things are:
1. **Regular scrubs** (automated monthly)
2. **SMART monitoring** (catch failures early)
3. **Actual backups** (test them regularly)

Keep your pool below 80% capacity, maintain good cooling, and your NAS will serve you reliably for years to come.

---

*Last updated: November 2025*
