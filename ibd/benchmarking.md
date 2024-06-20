# achow101's 5/13 benchmarking stream

https://www.twitch.tv/videos/2144867882

## Methodology
Ran three IBD's, all with  -assumevalid=0 and connecting to the same local node
in order to isolate from network variables.

All three were run with the same hardware and the following options:
```
-assumevalid='0'
-connect='127.0.0.1:8333' # all three synced from a local network node.
-debug='bench' -debug='validation' -debug='coindb'
-listen=false
-wallet=false
-shrinkdebugfiles='0' # prevent shrinking of logs (~2.5)
-logtimemicros # log events with better than single second precision
```

> Why -assumevalid=0? In order to remove the slowdown that would take place once
> we reached the assumevalid checkpoint to make the data more consistent.

The variables that were changed were dbcache and pruning.

1. The first run was with a dbcache of 200,000 (MiB) and pruning off.

2. The second run was run with the default dbcache (450 MiB) and pruning off.

3. The third run was run with `-prune=550` (max prune) and default dbcache (450
   MiB)

achow added benchmark logging for time to read 
