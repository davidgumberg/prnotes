## Flame Graphs

Flame graphs are a way of visualizing software CPU and heap profiles. Any tool
that can create stack data in the correct format can be used to generate a flame
graph. The flame graphs themselves are SVG files that have a small
amount of embedded Javascript that provide mouseover events and some functions
for zooming and filtering. They can also be viewed in regular image viewers or
browsers that have Javascript enabled.


Example (**[interactive SVG](https://monad.io/bitcoin-flamegraph.svg)**):

![Example Flamegraph](https://monad.io/bitcoin-flamegraph.svg)

You can learn more about flame graphs
[on Brendan Gregg's site](http://www.brendangregg.com/flamegraphs.html).

## Generating Flame Graphs On Linux

The Linux kernel project maintains a tool named `perf` that provides a high level
interface to the
[perf_event_open(2)](http://www.man7.org/linux/man-pages/man2/perf_event_open.2.html)
system call. Perf lets you generate accurate CPU profiles of kernel events and
userspace applications with relatively low overhead. This is the recommended way
to generate flame graphs on Linux, as it is lower overhead than other options
and allows generating profiles that can inspect kernel time.

For more information about `perf`:

 * [Perf Tutorial](https://perf.wiki.kernel.org/index.php/Tutorial)
 * [Perf Examples](http://www.brendangregg.com/perf.html)

### Installation

Perf is available on most Linux distros in a package named `perf` or some
variant thereof:

```bash
# Install perf on Debian.
sudo apt-get install linux-perf

# Install perf on Fedora.
sudo dnf install perf
```

To generate flame graphs with labeled function names you'll need a build of
Bitcoin that has debugging symbols enabled (this should be the case by default).
On Linux you can check that your executable has debugging symbols by checking for a
`.debug_str` section in the ELF file:, e.g.

```bash
# If this produces output your binary has debugging symbols.
$ readelf -S build/src/bitcoind | grep .debug_str
```

On most distros outside of Debian, you can probably install a package named
something like `js-d3-flame-graph`:

```bash
# On most yum/dnf based distros
sudo dnf install js-d3-flame-graph
```

<details> 

<summary>

#### d3-flame-graph template if no package is available

</summary>

On many systems, an HTML template that is required for perf to generate
interactive flamegraphs is available as a package named something like
`d3-flame-graph`:

```bash
# On fedora:
sudo dnf install d3-flame-graph
```

Installing as a package is not strictly necessary (and not possible e.g. on
Debian) since it's really just a single html file put in the place that the
`perf` tool expects to find it, so we can just create the directory with the
right permissions and download the file:

```bash
sudo mkdir -m 755 /usr/share/d3-flame-graph
# Check yourself that this is the right link! `perf` should tell you the url of
# the version of the template that it likes when it complains about the template
# missing.
sudo curl https://cdn.jsdelivr.net/npm/d3-flame-graph@4.1.3/dist/templates/d3-flamegraph-base.html -o /usr/share/d3-flame-graph/d3-flamegraph-base.html
```

Also, perf can grab the d3 template on it's own as long as you don't run it
in "live mode" (It's not "live mode" if you are creating a perf recording
and then converting it after), I imagine this issue will be fixed in the
future.

(https://lore.kernel.org/bpf/20230119183118.126387-3-irogers@google.com/T/)

</details>


### Frame pointer omission

When I put my ear to the street, I hear people saying that generating call
graphs from frame pointers is better than DWARF unwinding, since there is less
overhead, but I have not investigated this claim.

So, compile with `-fno-omit-frame-pointer`, or if you don't like that run `perf`
with `--call-graph dwarf`. (Overrides the default `--call-graph fp`)

```bash
$ cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DAPPEND_CPPFLAGS="-fno-omit-frame-pointer" -DBUILD_BENCH=ON
```

<details>

<summary>

### Enabling Kernel Annotations

</summary>

If you want kernel annotations (optional) then you should set the
`kernel.perf_event_paranoid` sysctl option is set to -1 before running `perf
record`. To set this option:

```bash
# Optional, enable kernel annotations, this option returns to your default after
# reboot.
sudo sysctl kernel.perf_event_paranoid=-1
```

You will also need kernel debug symbols:

```bash
# Set up debug symbols repo on Ubuntu
sudo apt install ubuntu-dbgsym-keyring
echo "deb http://ddebs.ubuntu.com $(lsb_release -cs) main restricted universe multiverse
deb http://ddebs.ubuntu.com $(lsb_release -cs)-updates main restricted universe multiverse
deb http://ddebs.ubuntu.com $(lsb_release -cs)-proposed main restricted universe multiverse" | \
sudo tee -a /etc/apt/sources.list.d/ddebs.list

# Install kernel debug symbols on Ubuntu and Debian.
sudo apt-get install linux-image-`uname -r`-dbg

# Install kernel debug symbols on Fedora.
sudo dnf debuginfo-install kernel
```

</details>

### Quick-start

Lucky enough, nowadays `perf` has a built in script for generating flame graphs
directly:

`perf script flamegraph <command>`

That's it, this will generate an interactive, searchable flamegraph.html file
that you can `firefox flamegraph.html` and start playing with once the command
completes.

#### Running process

To profile a running `bitcoind` process for 60 seconds you can use the following
command:

```bash
# Profile bitcoind for 60 seconds (replace PID).
perf script flamegraph -F 101 -p PID sleep 60
```

You should replace `PID` with the process ID of `bitcoind` (on most Linux
systems you can get this with `pidof bitcoind` or `pgrep bitcoind`).

The options `-g` and `--call-graph dwarf` are required to get stack traces. The
`-F` flag sets the sampling frequency; changing this is not strictly necessary,
but the default sample rate is very high and may be unsuitable for running for
long periods of time. The `perf record` command has many other options, for more
details see
[perf-record(1)](http://man7.org/linux/man-pages/man1/perf-record.1.html).

After running this command you'll have a `perf.data` in the current working
directory. Assuming that you have the perl scripts from the FlameGraph
repository in your `$PATH` you could generate a flame graph like so:

```bash
# Create a flame graph named "bitcoin.svg"
$ perf script | stackcollapse-perf.pl --all | flamegraph.pl > bitcoin.svg
```

The flags given above for `stackcollapse-perf.pl` and `flamegraph.pl` assume
you've applied the patch mentioned earlier for generating Bitcoin-specific color
coded flame graphs. They are not necessary unless you want color coded output.

The `perf record` command samples all threads in the target process. Often this
is not what you want, and you may want instead to generate a profile of a single
thread. This can be achieved by using `grep` to filter the output of
`stackcollapse-perf.pl` before it passes to `flamegraph.pl`. For instance, to
generate a profile of just the Bitcoin `loadblk` thread you might use an
invocation like:

```bash
# Create a flame graph of just the loadblk thread.
$ {
  perf script |
  stackcollapse-perf.pl --all |
  grep loadblk |
  flamegraph.pl --color bitcoin
} > loadblk.svg
```

You can get creative with how you use grep (or any other tool) to exclude or
include various parts of the collapsed stack data. The data format expected by
`flamegraph.pl` is very simple and can be manipulated in other interesting ways
(e.g. to collapse adjacent stack frames by class or file). See the upstream
FlameGraph repository for more examples.

## Generating Flame Graphs On macOS and Windows

The FlameGraph repository has scripts for processing the output of a large
number of other profiling tools.

**MacOS**: Follow the upstream instructions for generating flame graphs [using
DTrace](http://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html#Instructions).
There's also a guide for generating flame graphs using [XCode
Instruments](https://schani.wordpress.com/2012/11/16/flame-graphs-for-instruments/).

**Windows**: The FlameGraph repository has a script named
`stackcollapse-vsprof.pl` that can process Visual Studio profiler output.
