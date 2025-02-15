```bash
sha256sum ~/xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /home/user/xcode/Xcode_15.xip
docker pull fedora:40
docker run -it \
  -v ~/xcode:/xcode \
  fedora:40 \
  /bin/bash
```

Inside container:

```bash
sha256sum /xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /xcode/Xcode_15.xip
dnf install cpio git python -y
git clone --depth 1 https://github.com/bitcoin/bitcoin.git
git clone --depth 1 https://github.com/bitcoin-core/apple-sdk-tools.git
python3 apple-sdk-tools/extract_xcode.py -f /xcode/Xcode_15.xip | cpio -d -i
# 23498380 blocks
/bitcoin/contrib/macdeploy/gen-sdk Xcode.app/
# Found Xcode (version: 15.0, build id: 15A240d)
# Found MacOSX SDK (version: 14.0, build id: 23A334)
# Creating output .tar.gz file...
# Adding MacOSX SDK 14.0 files...
# Done! Find the resulting gzipped tarball at:
/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
sha256sum Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# 5b1a05d3e79fd14f5c8f6d3565762c89a522c7f5e7efbed4353d878410f2d765  Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# Wrong hash!
```

Ubuntu 24.04:

```bash
sha256sum ~/xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /home/user/xcode/Xcode_15.xip
docker pull ubuntu:24.04
docker run -it \
  -v ~/xcode:/xcode \
  ubuntu:24.04 \
  /bin/bash
```

```bash
export DEBIAN_FRONTEND=noninteractive # prevents apt from halting to interact
sha256sum /xcode/Xcode_15.xip
apt update
apt install cpio git python3 -y
git clone --depth 1 https://github.com/bitcoin/bitcoin.git
git clone --depth 1 https://github.com/bitcoin-core/apple-sdk-tools.git
python3 apple-sdk-tools/extract_xcode.py -f /xcode/Xcode_15.xip | cpio -d -i
# 23498380 blocks
/bitcoin/contrib/macdeploy/gen-sdk Xcode.app/
# Found Xcode (version: 15.0, build id: 15A240d)
# Found MacOSX SDK (version: 14.0, build id: 23A334)
# Creating output .tar.gz file...
# Adding MacOSX SDK 14.0 files...
# Done! Find the resulting gzipped tarball at:
# /Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
sha256sum Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# c0c2e7bb92c1fee0c4e9f3a485e4530786732d6c6dd9e9f418c282aa6892f55d  Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
```
