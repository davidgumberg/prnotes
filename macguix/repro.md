You first have to acquire the `Xcode_15.xip` archive according to the instructions in [`contrib/macdeploy/README.md`](https://github.com/bitcoin/bitcoin/tree/master/contrib/macdeploy#readme). The steps below assume you have placed this archive at `~/xcode/Xcode_15.xip`.

## Making the bad tarball using Fedora 40
### Container setup
```bash
sha256sum ~/xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /home/user/xcode/Xcode_15.xip
docker pull fedora:40
docker run -it \
  -v ~/xcode:/xcode \
  fedora:40 \
  /bin/bash
```

### In the container

```bash
sha256sum /xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /xcode/Xcode_15.xip
dnf install cpio git python -y
git clone --depth 1 https://github.com/bitcoin/bitcoin.git
git clone --depth 1 https://github.com/bitcoin-core/apple-sdk-tools.git
python3 apple-sdk-tools/extract_xcode.py -f /xcode/Xcode_15.xip | cpio -d -i
# 23498380 blocks
/bitcoin/contrib/macdeploy/gen-sdk Xcode.app/
sha256sum Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# 5b1a05d3e79fd14f5c8f6d3565762c89a522c7f5e7efbed4353d878410f2d765  Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# Wrong hash!
```

#### building python with another zlib

```bash
sudo dnf install gcc openssl-devel xz-devel
curl -L https://github.com/madler/zlib/releases/download/v1.3/zlib-1.3.tar.gz | tar xzvf -
cd zlib-1.3 && ./configure && make -j $(nproc) && make install && cd ..

curl https://pyenv.run | bash
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"

pyenv install 3.12.3
pyenv global 3.12.3

# verify zlib version
python -c "import zlib; print(zlib.ZLIB_VERSION)"
# 1.3

# regenerate Xcode.app
rm -rf Xcode.app/ && python3 apple-sdk-tools/extract_xcode.py -f /xcode/Xcode_15.xip | cpio -d -i
/bitcoin/contrib/macdeploy/gen-sdk Xcode.app/
sha256sum Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
```

## Making a good tarball using Ubuntu 24.04

### Container setup
```bash
sha256sum ~/xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /home/user/xcode/Xcode_15.xip
docker pull ubuntu:24.04
docker run -it \
  -v ~/xcode:/xcode \
  ubuntu:24.04 \
  /bin/bash
```

### In the container
```bash
export DEBIAN_FRONTEND=noninteractive # prevents apt from halting to interact
sha256sum /xcode/Xcode_15.xip
# 4daaed2ef2253c9661779fa40bfff50655dc7ec45801aba5a39653e7bcdde48e  /xcode/Xcode_15.xip
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

#### building python with a newer zlib

```bash
apt install -y build-essential curl liblzma-dev libssl-dev pkg-config
curl -L https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.2.3.tar.gz | tar xzvf -
cd zlib-ng-2.2.3/ && ./configure --zlib-compat && make -j $(nproc) && make install && cd ../

curl https://pyenv.run | bash
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"

pyenv install 3.12.8
pyenv global 3.12.8

# verify zlib version
python -c "import zlib; print(zlib.ZLIB_VERSION)"
# 1.3.1.zlib-ng


# try gen-sdk again
rm -rf Xcode.app/ && python3 apple-sdk-tools/extract_xcode.py -f /xcode/Xcode_15.xip | cpio -d -i
/bitcoin/contrib/macdeploy/gen-sdk Xcode.app/
sha256sum Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
# 5b1a05d3e79fd14f5c8f6d3565762c89a522c7f5e7efbed4353d878410f2d765  Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz

```

# Further investigation

`pkgdiff` reports the contents of the two tarballs are identical:

```console
$ sha256sum badsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
5b1a05d3e79fd14f5c8f6d3565762c89a522c7f5e7efbed4353d878410f2d765  badsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
$ sha256sum goodsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
c0c2e7bb92c1fee0c4e9f3a485e4530786732d6c6dd9e9f418c282aa6892f55d  goodsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
$ pkgdiff badsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz goodsdk/Xcode-15.0-15A240d-extracted-SDK-with-libcxx-headers.tar.gz
Reading packages ...
Comparing packages ...
creating report ...
result: UNCHANGED
```
<details> 

<summary> pkgdiff report screenshot </summary>

![Image](https://github.com/user-attachments/assets/364c072b-bcb1-412a-92b0-ea2491878865)

</details>

