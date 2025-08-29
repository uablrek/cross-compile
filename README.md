# Cross Compile

Cross compile is often non-trivial, but not so hard as you might
think. This repo describes how to cross compile to the ARM64
architecture (aarch64), for example to [RPi 4](
https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) and
[Radxa Rock 4se](https://wiki.radxa.com/Rock4/se) SoC boards.  I
rarely use official distributions, so native build is not an option,
besides it's *unbearably slow*.

[Development and contributions](#development-and-contributions) are
described below.

I use Ubuntu Linux (on an x86_64 pc), so some ways may not work, or
work differently, on other distros. But locally built tools, like
[musl-cross-make](https://github.com/richfelker/musl-cross-make),
should work.

For now I use `gcc`, but I will probably look at `clang` in the
future. I like the [clang cross compilation](
https://clang.llvm.org/docs/CrossCompilation.html) better, just use
another LLVM backend!

An advantage with cross compilation is that you can test your progams in
virtual environment (qemu-system-aarch64).

A *major* problem with cross compilation is (library) dependencies.
For native builds the libraries are installed, but not so when you
cross compile. Basically you have 2 options: extract the needed libs
from your target, or build them yourself. As I usually don't use a
target distribution, I take the second option.

Most things are done with the `admin.sh` script.

```
./admin.sh                    # help printout
./admin.sh env                # current settings
./admin.sh versions           # Used versions and download/clone status
```

Everything is built in `$XCOMPILE_WORKSPACE`, which defaults to
"/tmp/tmp/$USER/xcompile". Default for options can be set as
environment variables. Example:

```
export __arch=x86_64
```

Quick cross compile example:
```
# Cross compile a static BusyBox for aarch64
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
ver_busybox=busybox-1.36.1
curl --output-dir $HOME/Downloads -O -L https://busybox.net/downloads/$ver_busybox.tar.bz2
ws=/tmp/tmp/$USER/xcompile-test
mkdir -p $ws
tar -C $ws -xf $HOME/Downloads/$ver_busybox.tar.bz2
cp config/$ver_busybox $ws/$ver_busybox/.config
cd $ws/$ver_busybox
make menuconfig
# Set Settings>Cross compiler prefix to "aarch64-linux-gnu-" (tailing dash included)
make -j$(nproc)
file busybox   # Should be executable, ARM aarch64
#./admin.sh busybox_build    # Does the same thing
```

## Linux kernel

The Linux kernel is simple to cross compile. Always use the `O=`
option to kernel `make` to keep source and objects separated. This
allows the same source tree to be used for different builds.

```
#sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
ver_kernel=linux-6.15.7
curl --output-dir $HOME/Downloads -O https://cdn.kernel.org/pub/linux/kernel/v6.x/$ver_kernel.tar.xz
KERNELDIR=$HOME/tmp/linux
mkdir -p $KERNELDIR
tar -C $KERNELDIR -xf $HOME/Downloads/$ver_kernel.tar.xz
cd $KERNELDIR/$ver_kernel
ws=/tmp/tmp/$USER/xcompile-test/aarch64
__kobj=$ws/obj/$ver_kernel
make  O=$__kobj ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- virt.config
make O=$__kobj ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
```

Or
```
export __kcfg=/tmp/linux.config
export __arch=aarch64
./admin.sh kernel_build --initconfig=virt.config
```

## Test with qemu

With a kernel and a static busybox we can test to cross compile a
program and run it in `qemu`. First, the program:

```
cat > /tmp/hello.c <<EOF
#include <stdio.h>
int main(int argc, char* argv[])
{
    printf("Hello, world!\n");
    return 0;
}
EOF
mkdir -p /tmp/root-aarch64
aarch64-linux-gnu-gcc -static -o /tmp/root-aarch64/hello /tmp/hello.c
```

Now build the kernel and `BusyBox` and test it:
```
unset __kcfg      # (if you have set it above)
./admin.sh setup
./admin.sh qemu --root=/tmp/root-aarch64
# In qemu
uname -a
./hello
<ctrl-c>      # to exit
```

## Dynamic linking

So far we have used statically linked programs. For dynamically liked
programs we need a `loader` and the libraries. Build with:

```
aarch64-linux-gnu-gcc -o /tmp/root-aarch64/hello /tmp/hello.c
file /tmp/root-aarch64/hello
```

If you try to run again i `qemu`, you will get a `./hello: not found`.
This is confusing, because `./hello` *is* there. You can see it with
`ls`! But what's not found is the loader: `/lib/ld-linux-aarch64.so.1`.
So, let's add it and try again:

```
mkdir -p /tmp/root-aarch64/lib
cp /usr/aarch64-linux-gnu/lib/ld-linux-aarch64.so.1 /tmp/root-aarch64/lib
```
This time you get:
```
./hello: error while loading shared libraries: libc.so.6: cannot open shared object file: No such file or directory
```
which is an improvement. Add the lib and try again:
```
cp /usr/aarch64-linux-gnu/lib/libc.so.6 /tmp/root-aarch64/lib
```
Success!

### ldd

The `ldd` program lists the dynamic library dependencies for a
program. You don't have `ldd` in `qemu` but you can do what `ldd` does
(it's likely a script on your pc):

```
# In qemu
~ # LD_TRACE_LOADED_OBJECTS=1 ./hello 
        linux-vdso.so.1 (0x0000ffff940ed000)
        libc.so.6 => /lib/libc.so.6 (0x0000ffff93ef0000)
        /lib/ld-linux-aarch64.so.1 (0x0000ffff940b0000)
```

You can use a similar command on your pc. Please check `man ld-linux.so`
for more info.


## Musl libc

[Musl libc](https://musl.libc.org/) is an alternative to GNU libc. It
produces smaller binaries, and has a more relaxed license (important
for static linking). It is used for instance by
[Alpine Linux](https://www.alpinelinux.org/).

On Ubuntu `musl` is available for native builds:
```
sudo apt install musl-dev:amd64
gcc /tmp/hello.c -static -o /tmp/hello-gnu
x86_64-linux-musl-gcc /tmp/hello.c -static -o /tmp/hello-musl
ll /tmp/hello-*
-rwxrwxr-x 1 uablrek uablrek 767K Jul 21 09:23 /tmp/hello-gnu*
-rwxrwxr-x 1 uablrek uablrek  25K Jul 21 09:23 /tmp/hello-musl*
```

But we want to cross compile, and the recommended way is to use
[musl-cross-make](https://github.com/richfelker/musl-cross-make).

Clone and build:
```
export musldir=$HOME/tmp/musl-cross-make   # This is the default
git clone --depth=1 https://github.com/richfelker/musl-cross-make.git $musldir
./admin.sh musl-cross-make-build   # (takes ~9m on my 24-core i9!)
```

Now you can cross compile with `musl`, and test with `qemu`:

```
export PATH=$PATH:$musldir/aarch64/bin
mkdir -p /tmp/root-aarch64/lib /tmp/root-aarch64/bin
aarch64-linux-musl-gcc -o /tmp/root-aarch64/hello /tmp/hello.c
file /tmp/root-aarch64/hello
cp $musldir/aarch64/aarch64-linux-musl/lib/libc.so /tmp/root-aarch64/lib
ln -s libc.so /tmp/root-aarch64/lib/ld-musl-aarch64.so.1
ln -s /lib/libc.so /tmp/root-aarch64/bin/ldd
./admin.sh qemu --root=/tmp/root-aarch64
# In qemu
./hello
ldd ./hello
```

As you may notice the musl `/lib/libc.so` is a multi-purpose file. It
works as loader and `ldd` also.


## Open Source SW

This is what you usually want to cross compile. They will have a
build system, for instance:

* Makefile (yay!)
* Autotools (should have died in the 1990's)
* meson (with or without "ninja")
* cmake
* kconfig (the Linux kernel system. Used by BusyBox and U-boot for instance)
* Some more-or-less sane script
* Totally insane build system ([EDK2](https://github.com/tianocore/edk2))
* Native build *required* (systemd)

All except the last 2 can usually be cross compiled without too much
effort.

### Makefile

If a `Makefile` exist it may be enough to set some variables:

```
make CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar ..."
```

If not, you must check the `Makefile`, but since it's written by hand
it's probably readable. SW with a `Makefile` are almost always easy to
fix.

### Autotools

If these are well maintained, it *should* be enough to do:

```
./configure --host=aarch-linux-gnu ...
make ...
# Or;
CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar ./configure ...
make ...
```

Unfortunately, cross compile seems rarely tested by the maintainers.
If it fails, you might be in trouble.

### meson

Cross compilation is defined in a file. Examples exist in the
`config/` directory. If a `meson` project is well maintained, it
*should* be enough to do:

```
meson setup --cross-file config/meson-cross.aarch64 ...
meson compile ...
```

### cmake

Cross compilation with `cmake` is described [here](
https://cmake.org/cmake/help/book/mastering-cmake/chapter/Cross%20Compiling%20With%20CMake.html).
"cmake_toolchain" files are included in `config/`, but are not well
tested.


### kconfig

The [kernel build system](
https://www.kernel.org/doc/html/next/kbuild/kconfig-language.html)
should *really* be used by more complex open source projects, instead
of a vast array of (more-or-less undocumented) options to autotools,
meson or cmake.

Anyway, I have not seen any project that uses `kconfig` that doesn't
support cross compile.



## Dependencies

As mentioned, this can be a *major* problem. I use a "system directory"
(sysd) where SW packages are installed. A later builds can refer to the 
`sysd` rather than individual already-built packages.


### pkg-config

Many Open Source projects use [pkg-config](
https://en.wikipedia.org/wiki/Pkg-config). Then we don't have to
configure each dependency (`-I` and `-L` flags) manually.

```
./admin.sh expat_build
./admin.sh pkgconfig pkg-config --libs --cflags expat
-I/tmp/tmp/uablrek/xcompile/aarch64/sys/usr/local/include -L/tmp/tmp/uablrek/xcompile/aarch64/sys/usr/local/lib -lexpat
```

## Examples

The `admin.sh` scripts include some examples. To use them you must
download the libraries:

```
curl -L --output-dir $HOME/Downloads -O https://github.com/libexpat/libexpat/releases/download/R_2_7_1/expat-2.7.1.tar.xz
curl -L --output-dir $HOME/Downloads -O https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz
curl -L --output-dir $HOME/Downloads -O https://gitlab.freedesktop.org/xorg/lib/libpciaccess/-/archive/libpciaccess-0.18.1/libpciaccess-libpciaccess-0.18.1.tar.bz2
curl -L --output-dir $HOME/Downloads -O https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.bz2
./admin versions
```

Then build them in order. Please note that `libpciaccess` depends on `zlib`.

```
#export __musl=yes         # (if you want)
#export __native=yes       # (no cross compilation)
./admin.sh expat_build
./admin.sh zlib_build
./admin.sh libpciaccess_build
./admin.sh pcre2_build
```

For a more ambitious project, please check my [sdl-without-x11](
https://github.com/uablrek/sdl-without-x11). Perhaps I have
taken on more that I can chew since the project is not finished.


## Development and contributions

Issues and PR's are welcome. Please note that the license is CC0-1.0,
meaning that everything you contribute will become public domain.

By default everything is stored under `/tmp/tmp/$USER` because I mount
a tmpfs (ramdisk) on `/tmp/tmp` for experiments. You may change that
by setting the `$TEMP` environment variable.

The kernel source will be unpacked in `$KERNELDIR` if necessary, which
defaults to `$HOME/tmp/linux`. The kernel is not built in this
directory, so you may write-protect it if you like.
