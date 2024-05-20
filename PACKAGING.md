# Packaging river for distribution

First of all, I apologize for writing river in Zig. It will likely make
your job harder until Zig is more mature/stable. I do however believe that
writing my software in Zig allows me to deliver the best quality I can
despite the drawbacks of depending on a relatively immature language/toolchain.

## Source tarballs

Source tarballs with stable checksums and git submodule sources included may
be found on the [codeberg releases page](https://codeberg.org/river/river/releases).
These tarballs are signed with the PGP key available on my website at
<https://isaacfreund.com/public_key.txt>.

For the 0.1.3 release for example, the tarball and signature URLs are:
```
https://codeberg.org/river/river/releases/download/v0.1.3/river-0.1.3.tar.gz
https://codeberg.org/river/river/releases/download/v0.1.3/river-0.1.3.tar.gz.sig
```

## Zig version

Until Zig 1.0, Zig releases will often have breaking changes that prevent
river from building. River tracks the latest minor version Zig release
and is only compatible with that release and any patch releases. At the time
of writing for example river is compatible with Zig 0.9.0 and 0.9.1 but
not Zig 0.8.0 or 0.10.0.

## Zig Package Manager

River uses the built-in Zig package manager for its (few) Zig dependencies.
By default, running `zig build` will fetch river's Zig dependencies from the
internet and store them in the global zig cache before building river. Since
accessing the internet is forbidden or at least frowned upon by most distro
packaging infrastructure, there are ways to fetch the Zig dependencies in a
separate step before building river:

1. Fetch step with internet access:

   For each package in the `build.zig.zon` manifest file run the following command
   with the tarball URL in the `build.zig.zon`:

   ```
   zig fetch --global-cache-dir /tmp/foobar $URL
   ```

   This command will download and unpack the tarball, hash the contents of the
   tarball, and store the contents in the `/tmp/foobar/p/$HASH` directory. This
   hash should match the corresponding hash field in the `build.zig.zon`.

2. Build step with no internet access:

   The `--system` flag for `zig build` takes a path to an arbitrary directory in
   which zig packages stored in subdirectories matching their hash can be found.

   ```
   zig build --system /tmp/foobar/p/ ...
   ```

   This flag will disable all internet access and error if a package is not found
   in the provided directory.

It is also possible for distros to distribute Zig package manager packages as
distro packages, although there are still some rough edges as the support for
this is not yet mature. See this patchset for Chimera Linux for an example of
how this can work: https://github.com/chimera-linux/cports/pull/1395

## Build options

River is built using the Zig build system. To see all available build
options run `zig build --help`.

Important: By default Zig will build for the host system/cpu using the
equivalent of `-march=native`. To produce a portable binary `-Dcpu=baseline`
at a minimum must be passed.

Here are a few other options that are particularly relevant to packagers:

- `-Dcpu=baseline`: Build for the "baseline" CPU of the target architecture,
or any other CPU/feature set (e.g. `-Dcpu=x86_64_v2`).

  - Individual features can be added/removed with `+`/`-`
  (e.g. `-Dcpu=x86_64+avx2-cmov`).

  - For a list of CPUs see for example `zig targets | jq '.cpus.x86_64 |
  keys'`.

  - For a list of features see for example `zig targets | jq
  '.cpusFeatures.x86_64'`.

- `-Dtarget=x86_64-linux-gnu`: Target architecture, OS, and ABI triple. See
the output of `zig targets` for an exhaustive list of targets and CPU features,
use of `jq(1)` to inspect the output recommended.

- `-Dpie`: Build a position independent executable.

- `-Dstrip`: Build without debug info. This not the same as invoking `strip(1)`
on the resulting binary as it prevents the compiler from emitting debug info
in the first place. For greatest effect, both may be used.

- `--sysroot /path/to/sysroot`: Set the sysroot for cross compilation.

- `--libc my_libc.txt`: Set system libc paths for cross compilation. Run
`zig libc` to see a documented template for what this file should contain.

- Enable compiler optimizations:

  - `-Doptimize=ReleaseSafe`: Optimize for execution speed,
  keep all assertions and runtime safety checks active.

  - `-Doptimize=ReleaseFast`: Optimize for execution speed,
  disable all assertions and runtime safety checks.

  - `-Doptimize=ReleaseSmall`: Optimize for binary size,
  disable all assertions and runtime safety checks.

Please use `-Doptimize=ReleaseSafe` when building river for general
use. CPU execution speed is not the performance bottleneck for river, the
GPU is. Additionally, the increased safety is more than worth the binary
size trade-off in my opinion.

## Build prefix and DESTDIR

To control the build prefix and directory use `--prefix` and the `DESTDIR`
environment variable. For example
```bash
DESTDIR="/foo/bar" zig build --prefix /usr install
```
will install river to `/foo/bar/usr/bin/river`.

The Zig build system only has a single install step, there is no way to build
artifacts for a given prefix and then install those artifacts to that prefix
at some later time. However, much existing distribution packaging tooling
expect separate build and install steps. To fit the Zig build system into this
tooling, I recommend the following pattern:

```bash
build() {
    DESTDIR="/tmp/river-destdir" zig build --prefix /usr install
}

install() {
    cp -r /tmp/river-destdir/* /desired/install/location
}
```

## River specific suggestions

I recommend installing the example init file found at `example/init` to
`/usr/share/examples/river/init` or similar if your distribution has such
a convention.

## Examples

Build for the host architecture and libc ABI:
```bash
DESTDIR=/foo/bar zig build -Doptimize=ReleaseSafe -Dcpu=baseline \
    -Dstrip -Dpie --prefix /usr install
```

Cross compile for aarch64 musl libc based linux:
```bash
cat > xbps_zig_libc.txt <<-EOF
    include_dir=${XBPS_CROSS_BASE}/usr/include
    sys_include_dir=${XBPS_CROSS_BASE}/usr/include
    crt_dir=${XBPS_CROSS_BASE}/usr/lib
    msvc_lib_dir=
    kernel32_lib_dir=
    gcc_dir=
EOF

DESTDIR="/foo/bar" zig build \
    --sysroot "${XBPS_CROSS_BASE}" \
    --libc xbps_zig_libc.txt \
    -Dtarget=aarch64-linux-musl -Dcpu=baseline \
    -Doptimize=ReleaseSafe -Dstrip -Dpie \
    --prefix /usr install
```

## Questions?

If you have any questions feel free to reach out to me at
`mail@isaacfreund.com` or in `#zig` or `#river` on `irc.libera.chat`, my
nick is `ifreund`.
