# httprpc.cpp

- What is `httprpc.cpp`? 

- Why isn't it in the rpc folder?

## `class HTTPRPCTimer : public RPCTimerBase`

    "Simple one-shot callback timer to be used by the RPC mechanism to e.g.
    re-lock the wallet."

Constructed with a `struct event_base* eventBase` 
