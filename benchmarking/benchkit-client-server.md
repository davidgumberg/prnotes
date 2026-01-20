# Dream

I would like to be able to command a fleet of various hardware and operating
system's to run a bitcoind IBD benchmark. Ideally I could tell them "hey! do one
IBD with this commit hash and one IBD with this commit hash!" and I could come
back the next day and see stats and profiling information for both hashes on
every hardware device in the fleet. Device configuration should be out of scope
for this tool, things like filesystems, operating systems, and all other
configuration should be stable for each device in the fleet, this is both to
narrow the scope of independent variables here to different branches and
settings in bitcoin core on a static set of hardware/software configurations,
but also to avoid the implementation complexity of orchestrating configurations
for devices that won't all be running Linux/NixOS :D (Windows, MacOS, ¿Android?)

## Benchmark DSL

Benchkit is already a great tool for specifying IBD benchmarks declaratively,
with commit hashes, and heights, and parameterization, etc.

## Orchestration

What is left is the orchestration layer:

## Message Flow

The server publishes a message "Hey, this is the latest task." and all connected benchmarking machines add the task to their queue, and report results back to the server once they've finished.

## Security

The clients should authenticate the server since the server can make the clients run arbitrary code, the server can attach some unique id for each job that it assigns and only listen to reports for jobs that it assigned, and doesn't need to authenticate clients. The worst thing that can happen in this scenario, is a misbehaving client could make false reports to the server about the results of others' runs, but the server would receive multiple reports so it would be obvious that something was wrong.
