# Cross Compile

Cross compile is often non-trivial, but not so hard as you might
think. This repo describes how to cross compile to the ARM64
architecture (aarch64), for example to [RPi 4](
https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) and
[Radxa Rock 4se](https://wiki.radxa.com/Rock4/se) SoC boards.  I
rarely use official distributions, so native build is not an option,
besides it's *unbearably slow*.

I use Ubuntu Linux (on an x86_64 pc), so some ways may not work, or
work differently, on other distros. But locally built tools like,
[musl-cross-make](https://github.com/richfelker/musl-cross-make),
should work.

For now I use `gcc`, but I will probably look at `clang` in the
future. I like the [clang cross compilation](
https://clang.llvm.org/docs/CrossCompilation.html) better, just use
another LLVM backend!

An advantage with cross compilation is that you can test your progams in
virtual environment (qemu-system-aarch64).

A *major* problem with cross compilation is library dependencies.
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
export __arch=aarch64
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
#./admin.sh busybox_build --arch=aarch64   # Does the same thing
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
export __arch=aarch64
export __kcfg=/tmp/linux.config
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

Now build the kernel and `BosyBox` and test it:
```
export __arch=aarch64
unset __kcfg      # (if you have set it above)
./admin.sh setup --clean
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
produces smaller binaries, and has a more relaxed license. It is used
for instance by [Alpine Linux](https://www.alpinelinux.org/).

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

To be continued...
