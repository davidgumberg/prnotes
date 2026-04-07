```bash
# The reason a Dockerfile is needed is to get systemd installed and running in
# the container.
mkdir -p /tmp/fedora-systemd-container && cd /tmp/fedora-systemd-container
cat > ./Dockerfile << 'EOF'
FROM registry.fedoraproject.org/fedora:43
RUN dnf update -y
RUN dnf -y install git make systemd wget
CMD ["/lib/systemd/systemd"]
EOF

# I haven't confirmed, but I don't think getting systemd running is as easy
# with docker
podman build -t fedora-systemd .
podman run -d --replace --name fedora-systemd --systemd=always fedora-systemd
podman exec -it fedora-systemd /bin/bash
```

Inside the container shell:

```bash
git config --global merge.conflictstyle zdiff3

# https://guix.gnu.org/manual/en/html_node/Binary-Installation.html#Binary-Installation-1
cd /tmp
wget -O guix-install.sh https://guix.gnu.org/install.sh
chmod +x guix-install.sh
yes '' | ./guix-install.sh

git clone https://github.com/bitcoin/bitcoin.git --depth 1 && cd bitcoin
HOSTS=x86_64-linux-gnu ./contrib/guix/guix-build
```

Modified container setup with ubuntu:

```bash
mkdir -p /tmp/ubuntu-systemd-container && cd /tmp/ubuntu-systemd-container
cat > ./Dockerfile << 'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt-get install -y curl git gpg systemd make uidmap wget xz-utils
CMD ["/lib/systemd/systemd"]
EOF

podman build -t ubuntu-systemd .
podman run -d --replace --name ubuntu-systemd --systemd=always ubuntu-systemd
podman exec -it ubuntu-systemd /bin/bash
```
