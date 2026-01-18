# eRemote Server EC2 Deployment Guide

This guide covers deploying and operating the eRemote server on AWS EC2.

## Prerequisites

- AWS EC2 instance (Ubuntu 22.04 or Amazon Linux 2023 recommended)
- Docker installed on the instance
- IAM role attached to EC2 with ECR pull permissions
- Security group allowing ports: 21115-21119 (TCP), 21116 (UDP)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    EC2 Instance                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              eremote-server container                │   │
│  │  ┌─────────────┐    ┌─────────────┐                 │   │
│  │  │    hbbr     │    │    hbbs     │                 │   │
│  │  │   (relay)   │    │ (rendezvous)│                 │   │
│  │  └─────────────┘    └─────────────┘                 │   │
│  │         │                  │                         │   │
│  │         └────────┬─────────┘                        │   │
│  │                  │                                   │   │
│  │            /root (WORKDIR)                          │   │
│  └──────────────────┼──────────────────────────────────┘   │
│                     │ volume mount                          │
│              /opt/eremote (host)                            │
│              ├── id_ed25519       (private key)             │
│              ├── id_ed25519.pub   (public key)              │
│              └── db_v2.sqlite3    (peer database)           │
└─────────────────────────────────────────────────────────────┘
```

## Security Model

### Key Generation
- Identity keys (`id_ed25519`, `id_ed25519.pub`) are generated at **runtime** on first start
- Keys are **never** baked into the Docker image
- Keys persist on the host volume across container restarts

### Volume Mount
```bash
-v /opt/eremote:/root
```
This mounts the host directory `/opt/eremote` to the container's `/root` where eRemote stores:
- `id_ed25519` - Server private key (NEVER share this)
- `id_ed25519.pub` - Server public key (distribute to clients)
- `db_v2.sqlite3` - Peer registration database

### IAM Role (No Credentials on Disk)
The EC2 instance should have an IAM role with the following policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage"
            ],
            "Resource": "*"
        }
    ]
}
```

## Manual Deployment

### 1. Prepare the Host

```bash
# Create persistent data directory
sudo mkdir -p /opt/eremote
sudo chown $USER:$USER /opt/eremote

# Install Docker if not present
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

### 2. Login to ECR

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  752681609007.dkr.ecr.us-east-1.amazonaws.com
```

### 3. Run the Container

```bash
docker run -d \
  --name eremote-server \
  --restart unless-stopped \
  -p 21115:21115 \
  -p 21116:21116 \
  -p 21116:21116/udp \
  -p 21117:21117 \
  -p 21118:21118 \
  -p 21119:21119 \
  -v /opt/eremote:/root \
  -e RELAY_HOST=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) \
  752681609007.dkr.ecr.us-east-1.amazonaws.com/eremote-server:latest
```

### 4. Verify Deployment

```bash
# Check container status
docker ps --filter "name=eremote-server"

# View logs
docker logs -f eremote-server

# Check for generated keys
ls -la /opt/eremote/
cat /opt/eremote/id_ed25519.pub
```

## Automatic Updates with Watchtower

For automatic container updates when new images are pushed:

```bash
docker run -d \
  --name watchtower \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e WATCHTOWER_CLEANUP=true \
  -e WATCHTOWER_POLL_INTERVAL=300 \
  containrrr/watchtower \
  eremote-server
```

Watchtower will:
- Check for new images every 5 minutes
- Automatically pull and restart the container
- Clean up old images

## Port Reference

| Port  | Protocol | Service | Description |
|-------|----------|---------|-------------|
| 21115 | TCP      | hbbs    | NAT type test |
| 21116 | TCP+UDP  | hbbs    | ID registration & heartbeat |
| 21117 | TCP      | hbbr    | Relay connections |
| 21118 | TCP      | hbbs    | WebSocket for web clients |
| 21119 | TCP      | hbbr    | WebSocket relay |

## Backup and Recovery

### Backup Keys

```bash
# Backup identity keys (do this ONCE and store securely)
sudo cp /opt/eremote/id_ed25519 /secure/backup/location/
sudo cp /opt/eremote/id_ed25519.pub /secure/backup/location/
```

### Restore to New Instance

```bash
# On new instance
sudo mkdir -p /opt/eremote
sudo cp /secure/backup/location/id_ed25519* /opt/eremote/
sudo chown -R root:root /opt/eremote

# Then run the container as normal
```

**Important**: If you lose the private key (`id_ed25519`), all clients will need to be reconfigured with the new server public key.

## Troubleshooting

### Container Won't Start
```bash
# Check logs
docker logs eremote-server

# Common issues:
# - Port already in use: another container or service on those ports
# - Permission denied: check /opt/eremote permissions
```

### Clients Can't Connect
1. Verify security group allows ports 21115-21119
2. Check server public IP is correct in client config
3. Verify firewall rules on EC2 instance
4. Check `docker logs eremote-server` for connection errors

### Key Issues
```bash
# Verify keys exist
ls -la /opt/eremote/id_ed25519*

# Get the public key for client configuration
cat /opt/eremote/id_ed25519.pub
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_HOST` | (none) | Public IP/hostname of relay server |
| `RELAY_PORT` | 21117 | Port for relay connections |

## Upgrading

### Via CI/CD (Recommended)
Push to `master` or `main` branch triggers automatic:
1. Build new image
2. Push to ECR
3. Deploy to EC2

### Manual Upgrade
```bash
# Pull latest image
docker pull 752681609007.dkr.ecr.us-east-1.amazonaws.com/eremote-server:latest

# Restart container
docker stop eremote-server
docker rm eremote-server

# Run new container (same command as initial deployment)
docker run -d \
  --name eremote-server \
  --restart unless-stopped \
  -p 21115:21115 \
  -p 21116:21116 \
  -p 21116:21116/udp \
  -p 21117:21117 \
  -p 21118:21118 \
  -p 21119:21119 \
  -v /opt/eremote:/root \
  -e RELAY_HOST=YOUR_PUBLIC_IP \
  752681609007.dkr.ecr.us-east-1.amazonaws.com/eremote-server:latest

# Clean up old images
docker image prune -f
```
