```Dockerfile
```

```bash
cat > /tmp/fedora-systemd-build/Dockerfile << 'EOF'
FROM registry.fedoraproject.org/fedora:43
RUN dnf update -y
RUN dnf -y install git make systemd wget
CMD ["/sbin/init"]
EOF

podman build -t fedora-systemd .
podman run -d  --name fedora-systemd --systemd=always fedora-systemd
podman exec -it fedora-systemd /bin/bash
```

```bash
git config --global merge.conflictstyle zdiff3

# https://guix.gnu.org/manual/en/html_node/Binary-Installation.html#Binary-Installation-1
cd /tmp
wget -O guix-install.sh https://guix.gnu.org/install.sh
chmod +x guix-install.sh
yes '' | ./guix-install.sh

git clone https://github.com/bitcoin/bitcoin.git --depth 1 && cd bitcoin
HOSTS=x86_64-linux-gnu ./contrib/guix/guix-build
