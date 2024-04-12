# Bitcoin Core's built-in http server

Built in http server for the RPC server that uses libevent for handling requests
asynchronously.

## `bool InitHttpServer`

Call `InitHTTPAllowList()`, failing if it fails.

Override libevent's logging by setting our own callback:

```cpp
event_set_log_callback(&libevent_log_cb);
```


## `InitHTTPAllowList()`

Initializes Access Control List (ACL) for the http rpc server.

Allowed subnets are stored in a static vector of `CSubNet`'s:

```cpp
static std::vector<CSubNet> rpc_allow_subnets;
```

IPv4 and and IPv6 local nets are allowed:

```cpp
rpc_allow_subnets.emplace_back(LookupHost("127.0.0.1", false).value(), 8);  // always allow IPv4 local subnet
rpc_allow_subnets.emplace_back(LookupHost("::1", false).value());  // always allow IPv6 localhost
```

We also parse network/CIDR and network/netmask subnets passed with the
`-rpcallowip` arg. `LookupSubNet` does the work of parsing a string into a
`CSubNet`.
