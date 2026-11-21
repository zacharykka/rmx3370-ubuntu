#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
OUT="${OUT:-$WS/out/server-build}"
PKG_DIR="$WS/out/debs"
mkdir -p "$PKG_DIR"

KREL=$(make -s -C "$WS/kernel" O="$OUT" ARCH=arm64 LOCALVERSION="" CROSS_COMPILE="ccache aarch64-linux-gnu-" kernelrelease)
echo "[pkg-kernel] kernelrelease=$KREL"
case "$KREL" in
  *+*) echo "ERROR: kernelrelease contains + ($KREL)" >&2; exit 1 ;;
esac

STAGE="$WS/out/pkg-linux-image-$KREL"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/boot" "$STAGE/usr/lib/linux-image-$KREL/qcom"

cp "$OUT/arch/arm64/boot/Image" "$STAGE/boot/vmlinuz-$KREL"
cp "$OUT/.config" "$STAGE/boot/config-$KREL"
cp "$OUT/System.map" "$STAGE/boot/System.map-$KREL"
cp "$OUT/arch/arm64/boot/dts/qcom/sm8250-realme-bitra.dtb" "$STAGE/usr/lib/linux-image-$KREL/qcom/"

make -C "$WS/kernel" O="$OUT" ARCH=arm64 LOCALVERSION="" CROSS_COMPILE="ccache aarch64-linux-gnu-" \
  INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$STAGE/lib/modules/$KREL/build" "$STAGE/lib/modules/$KREL/source"

cat > "$STAGE/DEBIAN/control" << CTRL
Package: linux-image-$KREL
Source: linux-bitra
Version: 1
Architecture: arm64
Maintainer: ut-bitra <ut-bitra@localhost>
Section: kernel
Priority: optional
Provides: linux-image
Description: Mainline Linux kernel $KREL for realme GT Neo 2 (RMX3370 / bitra)
 Upstream mainline Linux kernel built for realme GT Neo 2 headless Ubuntu Server.
CTRL

cat > "$STAGE/DEBIAN/postinst" << POST
#!/bin/sh
set -e
KREL="$KREL"
depmod -a "\$KREL" || true
if [ -d /etc/kernel/postinst.d ]; then
  run-parts --report --exit-on-error --arg="\$KREL" --arg="/boot/vmlinuz-\$KREL" /etc/kernel/postinst.d
fi
exit 0
POST

cat > "$STAGE/DEBIAN/postrm" << POSTRM
#!/bin/sh
set -e
KREL="$KREL"
if [ -d /etc/kernel/postrm.d ]; then
  run-parts --report --exit-on-error --arg="\$KREL" --arg="/boot/vmlinuz-\$KREL" /etc/kernel/postrm.d
fi
exit 0
POSTRM

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

DEB="$PKG_DIR/linux-image-${KREL}_1_arm64.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"
ls -lh "$DEB"
