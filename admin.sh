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
		ver_musl=musl-cross-make-master \
		ver_expat=expat-2.7.1 \
		ver_zlib=zlib-1.3.1 \
		ver_libpciaccess=libpciaccess-libpciaccess-0.18.1 \
		ver_pcre2=pcre2-10.45
}
# Only called by qemu.sh
cmd_qemu_setup() {
	echo WS=$WS
	echo __arch=$__arch
	echo __musl=$__musl
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
	test "$__musl" = "yes" && WS=$WS-musl

	# Kernel/BusyBox/initrd is delegated to qemu.sh
	test "$cmd" = "qemu_setup" && return # short-circuit to prevent loop
	eset qemu=$dir/qemu.sh
	eval $($qemu versions --brief)  # ver_kernel ver_busybox

	eset \
		WS='' \
		__musl=no \
		musldir=$HOME/tmp/musl-cross-make \
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
		meson_setup="--cross-file $dir/config/$__arch/meson-cross-musl"
		export CMAKE_TOOLCHAIN_FILE=$WS/cmake/toolchain-musl
		if ! test -r $CMAKE_TOOLCHAIN_FILE; then
			mkdir -p $WS/cmake
			__sysd=$__sysd envsubst < $dir/config/$__arch/cmake_toolchain-musl\
				> $CMAKE_TOOLCHAIN_FILE
		fi
	else
		cc_setup="CC=$__arch-linux-gnu-gcc AR=$__arch-linux-gnu-ar"
		at_setup="--host=$__arch-linux-gnu"
		meson_setup="--cross-file $dir/config/$__arch/meson-cross"
		export CMAKE_TOOLCHAIN_FILE=$WS/cmake/toolchain
		if ! test -r $CMAKE_TOOLCHAIN_FILE; then
			mkdir -p $WS/cmake
			__sysd=$__sysd envsubst < $dir/config/$__arch/cmake_toolchain \
				> $CMAKE_TOOLCHAIN_FILE
		fi
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
	if test "$__brief" = "yes"; then
		set | grep -E 'ver_[a-z0-9]+='
		return 0
	fi
	local k v
	for k in $(set | grep -E 'ver_[a-z0-9]+=' | cut -d= -f1); do
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
##   setup [--clean] [--arch=] [--musl]
##     Build everything needed for qemu
cmd_setup() {
	test "$__clean" = "yes" && rm -rf $WS
	$qemu busybox_build || die busybox_build
	$qemu kernel_build || die kernel_build
}
##   rebuild [--arch=] [--musl] [--qemu]
##     Rebuild the test applications, and kernel/busybox/initrd if
##     --qemu is specified
cmd_rebuild() {
	local begin=$(date +%s) now
	rm -rf $WS
	local c
	for c in expat_build zlib_build libpciaccess_build pcre2_build; do
		$me $c || die $c
	done
	if test "$__qemu" = "yes"; then
		$qemu rebuild ovl/admin-install || die "qemu rebuild"
	fi
	now=$(date +%s)
	echo "Build for $(basename $WS) in $((now-begin)) sec"
}
##   rebuild-all
##     Rebuild for all targets (for test)
cmd_rebuild_all() {
	local begin=$(date +%s) now
	rm -rf $XCOMPILE_WORKSPACE
	$me rebuild --arch=x86_64 --musl=no --qemu || die "x86_64"
	$me rebuild --arch=x86_64 --musl=yes --qemu || die "x86_64-musl"
	$me rebuild --arch=aarch64 --musl=no --qemu || die "aarch64"
	$me rebuild --arch=aarch64 --musl=yes --qemu || die "aarch64-musl"
	now=$(date +%s)
	echo "Build for all targets in $((now-begin)) sec"
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
##   install [--dest=] [--force] [--base-libs-only]
##     Install base libs (including the loader) and built items
##     from $__sysd. If --dest is omitted installed files are printed.
##     The dest must NOT exist unless --force is specified
cmd_install() {
	if test -z "$__dest"; then
		install $tmp
		cd $tmp
		find . ! -type d | sed -e 's,^\./,,'
		cd $dir
	else
		if test -e $__dest; then
			test "$__force" = "yes" || die "Already exist [$__dest]"
		fi
		install $__dest
	fi
}
is_native() {
	test "$__musl" != "yes" -a "$__arch" = "x86_64"
}
install() {
	local lib=gnu
	test "$__musl" = "yes" && lib=musl
	install_${__arch}_$lib $1
	test "$__base_libs_only" = "yes" && return 0
	if is_native; then
		install_sys_native $1
	else
		install_sys $1
	fi
}
install_sys() {
	local d=$1/lib
	mkdir -p $d
	# We assume (for now) that all libs are installed in /usr/local
	local sys=$__sysd/usr/local
	cd $sys/lib
	cp $(find . | grep -E '^./lib.*\.so\.[0-9]+$') $d
	# Copy programs
	test -d $sys/bin || return 0
	mkdir -p $1/bin
	cd $sys/bin
	cp * $1/bin
}
install_sys_native() {
	# Libs goes to /lib/x86_64-linux-gnu. This may differ on other
	# distros than Ubuntu
	local d=$1/lib/x86_64-linux-gnu
	mkdir -p $d
	# We assume (for now) that all libs are installed in /usr/local
	local sys=$__sysd/usr/local
	test -d $sys/lib || die "Application not built"
	cd $sys/lib
	cp $(find . | grep -E '^./lib.*\.so\.[0-9]+$') $d
	# Copy native libs (different for applications)
	local lib
	for lib in libbz2.so.1.0 libreadline.so.8 libtinfo.so.6; do
		cp -L /lib/x86_64-linux-gnu/$lib $d || die "native lib [$lib]"
	done
	# Copy programs
	test -d $sys/bin || return 0
	mkdir -p $1/bin
	cd $sys/bin
	cp * $1/bin
}
install_musl() {
	local libd=$musldir/$__arch/$__arch-linux-musl/lib
	test -d $libd || die "Not a directory [$libd]"
	local d=$1/lib
	mkdir -p "$d" || die "Mkdir failed [$d]"
	cd $libd
	cp libc.so $d/ld-musl-$__arch.so.1
	cp -L $(find . | grep -E '^./lib.*\.so\.[0-9]+$') $d
	mkdir -p $1/bin
	ln -s /lib/ld-musl-$__arch.so.1 $1/bin/ldd
}
install_aarch64_musl() {
	install_musl $1
}
install_x86_64_musl() {
	install_musl $1
}
install_aarch64_gnu() {
	local libd=/usr/aarch64-linux-gnu
	local loader=/lib/ld-linux-aarch64.so.1
	test -x $libd$loader || "Not installed [aarch64-linux-gnu]"
	local d=$1/lib
	mkdir -p $d
	cd $libd
	cp -L $(find . | grep -E '.*\.so\.[0-9]+$') $d
	mkdir -p $1/etc
	echo "alias ldd='LD_TRACE_LOADED_OBJECTS=1 $loader'" >> $1/etc/profile	
}
install_x86_64_gnu() {
	# Native install
	mkdir -p $1/lib64
	local loader=/lib64/ld-linux-x86-64.so.2
	cp -L $loader $1/lib64 || die "loader"
	local d=$1/lib/x86_64-linux-gnu
	mkdir -p $d
	local lib
	for lib in libc.so.6 libm.so.6; do
		cp -L /lib/x86_64-linux-gnu/$lib $d || die $lib
	done
	mkdir -p $1/etc
	echo "alias ldd='LD_TRACE_LOADED_OBJECTS=1 $loader'" >> $1/etc/profile
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
	test -r "Makefile" || cmake $opt .. || die cmake
	make -j$(nproc) || die make
	make install -j$(nproc) DESTDIR=$__sysd || die "make install"
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
