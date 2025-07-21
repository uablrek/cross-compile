#! /bin/sh
##
## xcompile/admin.sh --
##
##   Admin script for cross-compile
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
me=$dir/$prg
test -n "$TEMP" || TEMP=/tmp/tmp/$USER
tmp=$TEMP/${prg}_$$

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}
test -n "$1" || help
echo "$1" | grep -qi "^help\|-h" && help

log() {
	echo "$*" >&2
}
findf() {
	local d
	for d in $(echo $FSEARCH_PATH | tr : ' '); do
		f=$d/$1
		test -r $f && return 0
	done
	unset f
	return 1
}
findar() {
	findf $1.tar.bz2 || findf $1.tar.gz || findf $1.tar.xz || findf $1.zip
}
# Set variables unless already defined. Vars are collected into $opts
eset() {
	local e k
	for e in $@; do
		k=$(echo $e | cut -d= -f1)
		opts="$opts|$k"
		test -n "$(eval echo \$$k)" || eval $e
	done
}
# cdsrc <version>
# Cd to the source directory. Unpack the archive if necessary.
cdsrc() {
	test -n "$1" || die "cdsrc: no version"
	test "$__clean" = "yes" && rm -rf $WS/$1
	if ! test -d $WS/$1; then
		findar $1 || die "No archive for [$1]"
		if echo $f | grep -qF '.zip'; then
			unzip -d $WS -qq $f || die "Unzip [$f]"
		else
			tar -C $WS -xf $f || die "Unpack [$f]"
		fi
	fi
	cmd_pkgconfig				# (define $PKG_CONFIG_LIBDIR)
	cd $WS/$1
}
# Define sw versions
# The pattern "name-ver" is de'facto standard
versions() {
	eset \
		ver_kernel=linux-6.15.7 \
		ver_busybox=busybox-1.36.1 \
		ver_musl=musl-cross-make-master \
		ver_expat=expat-2.7.1 \
		ver_zlib=zlib-1.3.1 \
		ver_libpciaccess=libpciaccess-libpciaccess-0.18.1 \
		ver_pcre2=pcre2-10.45
}
##   env
##     Print environment.
cmd_env() {
	test "$envset" = "yes" && return 0
	envset=yes
	versions
	unset opts

	eset ARCHIVE=$HOME/archive
	eset FSEARCH_PATH=$HOME/Downloads:$ARCHIVE
	eset XCOMPILE_WORKSPACE=/tmp/tmp/$USER/xcompile
	eset __arch=aarch64
	eset __native=no
	test "$__native" = "yes" && __arch=$(uname -m)
	WS=$XCOMPILE_WORKSPACE/$__arch
	eset KERNELDIR=$HOME/tmp/linux
	eset \
		WS='' \
		__musl=no \
		__kcfg=$dir/config/$ver_kernel-$__arch \
		__kdir=$KERNELDIR/$ver_kernel \
		__kobj=$WS/obj/$ver_kernel \
		__bbcfg=$dir/config/$ver_busybox \
		__initrd=$WS/initrd.bz \
		musldir=$HOME/tmp/musl-cross-make \
		kernel='' \
		__sysd=$WS/sys

	if test "$cmd" = "env"; then
		set | grep -E "^($opts)="
		exit 0
	fi

	mkdir -p $__sysd
	test -n "$long_opts" && export $long_opts

	if test "$__native" = "yes"; then
		cc_setup=''
		musl_setup=''
		meson_setup=''
	elif test "$__musl" = "yes"; then
		test -x $musldir/$__arch/bin/$__arch-linux-musl-gcc || \
			die "No musl cross-compiler built for [$__arch]"
		export PATH=$musldir/$__arch/bin:$PATH
		cc_setup="CC=$__arch-linux-musl-gcc AR=$__arch-linux-musl-ar"
		at_setup="--host=$__arch-linux-gnu"
		meson_setup="--cross-file $dir/config/meson-cross-musl.$__arch"
	else
		cc_setup="CC=$__arch-linux-gnu-gcc AR=$__arch-linux-gnu-ar"
		at_setup="--host=$__arch-linux-gnu"
		meson_setup="--cross-file $dir/config/meson-cross.$__arch"
	fi
	mkdir -p $WS || die "Can't mkdir [$WS]"
	if test "$__arch" = "aarch64"; then
		kernel=$__kobj/arch/arm64/boot/Image
	else
		kernel=$__kobj/arch/x86/boot/bzImage
	fi
	cd $dir
}
##   versions [--brief]
##     Print used sw versions
cmd_versions() {
	unset opts
	versions
	if test "$__brief" = "yes"; then
		set | grep -E "^($opts)="
		return 0
	fi
	local k v
	for k in $(echo $opts | tr '|' ' '); do
		v=$(eval echo \$$k)
		if findar $v; then
			printf "%-20s (%s)\n" $v $f
		else
			printf "%-20s (archive missing!)\n" $v
		fi
	done
}
##   clean
##     Remove the work-space
cmd_clean() {
	rm -rf $ws
}
##   setup [--clean]
##     Build everything needed for qemu
cmd_setup() {
	test "$__clean" = "yes" && rm -rf $WS
	$me busybox_build || die busybox_build
	$me kernel_build || die kernel_build
}
##   pkgconfig [--sysd=] [cmd]
##     Collect pkgconfig in --sysd to $__sysd/pkgconfig-sys.
##     Fixup pkgconfig files, and set $PKG_CONFIG_LIBDIR.
##     Used internally for build setup. Cli use:
##     ./admin.sh pkgconfig pkg-config --libs --cflags <lib>
cmd_pkgconfig() {
	local d
	mkdir -p $__sysd/pkgconfig-sys
	unset PKG_CONFIG_PATH
	export PKG_CONFIG_LIBDIR=$__sysd/pkgconfig-sys
	for d in $(find $__sysd -type d -name pkgconfig); do
		cp $d/* $PKG_CONFIG_LIBDIR
	done
	sed -i -e "s,prefix=/usr/local,prefix=$__sysd/usr/local," \
		$__sysd/pkgconfig-sys/* > /dev/null 2>&1
	if test "$cmd" = "pkgconfig"; then
		test -n "$1" && $@
	fi
}
##   strip <dir>
##     Recursive architecture and lib sensitive strip
cmd_strip() {
	test -n "$1" || die "No dir"
	test -d "$1" || die "Not a directory [$1]"
	local strip=strip
	test "$__musl" = "yes" && \
		strip=$musldir/$__arch/bin/$__arch-linux-musl-strip
	local f
	cd $1
	for f in $(find . -type f -executable); do
		file $f | grep -q ELF && $strip $f
	done
}
##   musl-cross-make-build
cmd_musl_cross_make_build() {
	if test -r $musldir/Makefile; then
		cd $musldir
	else
		cdsrc $ver_musl
	fi
	pwd
	local make="make -j$(nproc) GCC_VER=13.3.0"
	local target arch
	for arch in aarch64 x86_64; do
		target=$arch-linux-musl
		$make TARGET=$target || die "make $target"
		$make TARGET=$target install OUTPUT=$PWD/$arch \
			|| die "make $target install"
	done
}
##   musl_install <dest>
##     Install musl libs. This is a no-op if --musl is not specified
cmd_musl_install() {
	test "$__musl" = "yes" || return 0
	test -n "$1" || die "No dest"
	local libd=$musldir/$__arch/$__arch-linux-musl/lib
	test -d $libd || die "Not a directory [$libd]"
	mkdir -p "$1/lib" || die "Mkdir failed [$1/lib]"
	cp $libd/libc.so $1/lib/ld-musl-$__arch.so.1  # The loader
	cp -L $libd/lib*.so.[0-9] $1/lib
}
##   busybox_build [--bbcfg=] [--menuconfig]
##     Build BusyBox
cmd_busybox_build() {
	cdsrc $ver_busybox
	if test "$__menuconfig" = "yes"; then
		test -r $__bbcfg && cp $__bbcfg .config
		make menuconfig
		cp .config $__bbcfg
	else
		test -r $__bbcfg || die "No config"
		cp $__bbcfg .config
	fi
	test "$__native" != "yes" && \
		sed -i -E "s,CONFIG_CROSS_COMPILER_PREFIX=\"\",CONFIG_CROSS_COMPILER_PREFIX=\"$__arch-linux-gnu-\"," .config
	make -j$(nproc)
}
cmd_kernel_unpack() {
	test -d $__kdir && return 0	  # (already unpacked)
	log "Unpack kernel to [$__kdir]..."
	findar $ver_kernel || die "Kernel source not found [$ver_kernel]"
	mkdir -p $KERNELDIR
	tar -C $KERNELDIR -xf $f
}
##   kernel_build --initconfig=something_default  # Init the kcfg
##   kernel_build [--clean] [--menuconfig]
##     Build the kernel
cmd_kernel_build() {
	cmd_kernel_unpack
	test "$__clean" = "yes" && rm -rf $__kobj
	mkdir -p $__kobj

	local CROSS_COMPILE make targets
	make="make -C $__kdir O=$__kobj"
	if test "$__native" != "yes"; then
		if test "$__arch" = "aarch64"; then
			make="$make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
			targets="Image modules dtbs"
		else
			make="$make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu-"
		fi
	fi
	if test -n "$__initconfig"; then
		rm -r $__kobj
		mkdir -p $__kobj $(dirname $__kcfg)
		$make -C $__kdir O=$__kobj $__initconfig
		cp $__kobj/.config $__kcfg
		__menuconfig=yes
	fi

	test -r $__kcfg || die "Not readable [$__kcfg]"
	cp $__kcfg $__kobj/.config
	if test "$__menuconfig" = "yes"; then
		$make menuconfig
		cp $__kobj/.config $__kcfg
	else
		$make oldconfig
	fi
	$make -j$(nproc) $targets
}
##   initrd_build [--initrd=] [--root=dir]
##     Build a ramdisk (cpio archive) containing busybox and the --root
cmd_initrd_build() {
	local bb=$WS/$ver_busybox/busybox
	test -x $bb || die "Not executable [$bb]"
	touch $__initrd || die "Can't create [$__initrd]"

	cmd_gen_init_cpio
	gen_init_cpio=$WS/bin/gen_init_cpio
	mkdir -p $tmp
	cat > $tmp/cpio-list <<EOF
dir /dev 755 0 0
nod /dev/console 644 0 0 c 5 1
dir /bin 755 0 0
file /bin/busybox $bb 755 0 0
slink /bin/sh busybox 755 0 0
dir /etc 755 0 0
file /init $dir/config/init-tiny 755 0 0
EOF
	if test -n "$__root"; then
		test -d "$__root" || die "Not a directory [$__root]"
		cmd_emit_list $__root >> $tmp/cpio-list
	fi
	rm -f $__initrd
	local uncompressed=$(echo $__initrd | sed -E 's,.[a-z]+$,,')
	local compression=$(echo $__initrd | grep -oE '[a-z]+$')
	case $compression in
		xz)
			$gen_init_cpio $tmp/cpio-list > $uncompressed
			xz -T0 $uncompressed;;
		gz)
			$gen_init_cpio $tmp/cpio-list | gzip -c > $__initrd;;
		bz)
			$gen_init_cpio $tmp/cpio-list | bzip2 -c > $__initrd;;
		*)
			die "Unknown initrd compression [$compression]";;
	esac
}
#   gen_init_cpio
#     Build the kernel gen_init_cpio utility
cmd_gen_init_cpio() {
	local x=$WS/bin/gen_init_cpio
	test -x $x && return 0
	cmd_kernel_unpack	
	mkdir -p $(dirname $x)
	local src=$__kdir/usr/gen_init_cpio.c
	test -r $src || die "Not readable [$src]"
	gcc -o $x $src
}
#   emit_list <src>
#     Emit a gen_init_cpio list built from the passed <src> dir
cmd_emit_list() {
	test -n "$1" || die "No source"
	local x p target d=$1
	test -d $d || die "Not a directory [$d]"
	cd $d
	for x in $(find . -mindepth 1 -type d | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "dir $x $p 0 0"
	done
	for x in $(find . -mindepth 1 -type f | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "file $x $d$x $p 0 0"
	done
	for x in $(find . -mindepth 1 -type l | cut -c2-); do
		target=$(readlink $d$x)
		echo "slink $x $target 777 0 0"
	done
}
##   Examples:
##     expat_build
cmd_expat_build() {
	# Normal autotools cross-compile
	cdsrc $ver_expat
	test -r Makefile || ./configure $at_setup --without-docbook \
		--without-tests --without-examples || die "configure"
	make -j$(nproc) || die make
	make install DESTDIR=$__sysd || die "make install"
	cmd_pkgconfig
}
##     zlib_build
cmd_zlib_build() {
	# Simplified autotools cross-compile
	cdsrc $ver_zlib
	env $cc_setup ./configure || die "configure zlib"
	make -j$(nproc) || die make
	make install prefix=$__sysd/usr/local
}
##     libpciaccess_build
cmd_libpciaccess_build() {
	# Meson cross-compile
	cdsrc $ver_libpciaccess
	test -d build || meson setup $meson_setup -Dzlib=enabled build
	meson compile -C build || die build
	meson install -C build --destdir $__sysd
}
##     pcre2_build
cmd_pcre2_build() {
	# Cmake cross-compile. Use "cmake -LAH" to check options
	cdsrc $ver_pcre2
	local opt="-DBUILD_SHARED_LIBS=ON"
	mkdir -p build
	cd build
	test -r "Makefile" || env $cc_setup cmake $opt .. || die cmake
	make -j$(nproc) || die make
	make install -j$(nproc) DESTDIR=$__sysd || die "make install"
}

##   qemu [--root=dir]
##     Start a qemu VM. Optionally with files from --root
cmd_qemu() {
	test -r $kernel || die "Not readable [$kernel]"
	cmd_initrd_build
	rm -rf $tmp					# (since we 'exec')
	qemu_$__arch $@
}
qemu_x86_64() {
	exec qemu-system-x86_64 -enable-kvm -M q35 -m 128M -smp 2 \
		-nographic -append "init=/init" \
		-monitor none -serial stdio -kernel $kernel  -initrd $__initrd $@
}
qemu_aarch64() {
	exec qemu-system-aarch64 -nographic -cpu cortex-a72 \
		-machine virt,virtualization=on,secure=off \
		-append "init=/init" \
		-monitor none -serial stdio -kernel $kernel -initrd $__initrd $@

#		-drive if=none,file=fat:rw:$__root,format=raw,media=disk,id=hd \
#		-device virtio-blk-pci,drive=hd \
#		-hda fat:rw:$__root \
}

##
# Get the command
cmd=$(echo $1 | tr -- - _)
shift
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
	if echo $1 | grep -q =; then
		o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
		v=$(echo "$1" | cut -d= -f2-)
		eval "$o=\"$v\""
	else
		o=$(echo "$1" | sed -e 's,-,_,g')
		eval "$o=yes"
	fi
	long_opts="$long_opts $o"
	shift
done
unset o v

# Execute command
trap "die Interrupted" INT TERM
cmd_env
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status
