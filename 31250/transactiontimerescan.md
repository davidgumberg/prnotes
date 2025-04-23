Apparently, some rpc commands in the python test framework are lies!

In https://github.com/bitcoin/bitcoin/commit/869f7ab30aeb4d7fbd563c535b55467a8a0430cf,
class `RPCOverloadWrapper` was added to gracefully handle test cases that
relied on deprecated/disabled RPC's, but still tested meaningfully unique
behavior that was still possible with other RPC's.

