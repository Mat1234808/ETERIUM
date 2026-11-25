#!/bin/sh
set -e

WORK_DIR="$(pwd)"
OUT_DIR="$WORK_DIR/all-in-one-build"
ISO_ROOT="$OUT_DIR/iso_root"
FINAL_ISO="$WORK_DIR/ETHEREUM-Linux-Complete-AllInOne.iso"

run_git() { if [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" git "$@"; else git "$@"; fi; }

mkdir -p "$OUT_DIR"

build_branch() {
    BRANCH="$1"
    TARGET_ISO="$2"

    if [ -f "$TARGET_ISO" ] && [ "${FORCE_REBUILD:-}" != "$BRANCH" ]; then
        echo "===================================================="
        echo ">>> [PULANDO] $BRANCH ja compilada em: $TARGET_ISO"
        echo "===================================================="
        return 0
    fi

    echo "===================================================="
    echo ">>> Compilando branch: $BRANCH"
    echo "===================================================="
    run_git checkout "$BRANCH"
    sudo ./auto/clean
    sudo rm -rf cache/ .build/
    sudo nice -n 19 ./auto/build
    ISO_FOUND=$(ls -1 ethereum-*.hybrid.iso live-image-*.hybrid.iso 2>/dev/null | head -n 1)
    if [ -z "$ISO_FOUND" ]; then
        echo "ERRO: Nenhuma ISO gerada na branch $BRANCH"
        exit 1
    fi
    mv "$ISO_FOUND" "$TARGET_ISO"
}

# 1. Compila as 3 bases (Moderno/Intermediario, Legado 32-bit e Retro 486)
build_branch "main" "$OUT_DIR/ethereum-amd64.iso"
build_branch "arch-i386" "$OUT_DIR/ethereum-i686.iso"
build_branch "retro-i486" "$OUT_DIR/ethereum-i486.iso"

run_git checkout main

# 2. Limpa montagem anterior (se houver) e extrai a estrutura base (UEFI + BIOS)
echo ">>> Montando estrutura unificada da ISO..."
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT/live/amd64" "$ISO_ROOT/live/i686" "$ISO_ROOT/live/i486"

xorriso -osirrox on -indev "$OUT_DIR/ethereum-amd64.iso" \
    -extract /boot "$ISO_ROOT/boot" \
    -extract /EFI "$ISO_ROOT/EFI" \
    -extract /isolinux "$ISO_ROOT/isolinux" \
    -extract /live "$ISO_ROOT/live/amd64"

# 3. Extrai os sistemas 32-bit (i686) e Retro (i486)
xorriso -osirrox on -indev "$OUT_DIR/ethereum-i686.iso" -extract /live "$ISO_ROOT/live/i686"
xorriso -osirrox on -indev "$OUT_DIR/ethereum-i486.iso" -extract /live "$ISO_ROOT/live/i486"

chmod -R u+w "$ISO_ROOT"

# Normaliza nomes dos kernels para o menu de boot
cp $(ls "$ISO_ROOT/live/amd64/vmlinuz"* | head -n 1) "$ISO_ROOT/live/amd64/vmlinuz"
cp $(ls "$ISO_ROOT/live/amd64/initrd"* | head -n 1) "$ISO_ROOT/live/amd64/initrd.img"

cp $(ls "$ISO_ROOT/live/i686/vmlinuz"*686-pae* | head -n 1) "$ISO_ROOT/live/i686/vmlinuz-pae"
cp $(ls "$ISO_ROOT/live/i686/initrd"*686-pae* | head -n 1) "$ISO_ROOT/live/i686/initrd-pae.img"
cp $(ls "$ISO_ROOT/live/i686/vmlinuz"*-686 | grep -v pae | head -n 1) "$ISO_ROOT/live/i686/vmlinuz-nopae"
cp $(ls "$ISO_ROOT/live/i686/initrd"*-686 | grep -v pae | head -n 1) "$ISO_ROOT/live/i686/initrd-nopae.img"

cp $(ls "$ISO_ROOT/live/i486/vmlinuz"* | head -n 1) "$ISO_ROOT/live/i486/vmlinuz"
cp $(ls "$ISO_ROOT/live/i486/initrd"* | head -n 1) "$ISO_ROOT/live/i486/initrd.img"

# Copia modulo ifcpu64.c32 para deteccao automatica de 64-bit vs 32-bit no BIOS
for mod in /usr/lib/syslinux/modules/bios/ifcpu64.c32 /usr/lib/ISOLINUX/ifcpu64.c32; do
    [ -f "$mod" ] && cp "$mod" "$ISO_ROOT/isolinux/" && break
done

# 4. Configura menu BIOS (ISOLINUX) com deteccao automatica de arquitetura
cat > "$ISO_ROOT/isolinux/isolinux.cfg" << 'ISOCFG'
DEFAULT auto_detect
PROMPT 0
TIMEOUT 50

UI menu.c32
MENU TITLE ETHEREUM Linux - Boot Universal (64-bit / 32-bit / Retro)

LABEL auto_detect
    MENU LABEL ^Iniciar ETHEREUM Linux (Deteccao Automatica de Hardware)
    KERNEL ifcpu64.c32
    APPEND amd64_auto -- i686_auto

LABEL amd64_auto
    MENU LABEL ETHEREUM 64-bit (Moderno Cinnamon / Intermediario XFCE)
    LINUX /live/amd64/vmlinuz
    INITRD /live/amd64/initrd.img
    APPEND boot=live components live-media-path=/live/amd64 quiet

LABEL i686_auto
    MENU LABEL ETHEREUM 32-bit Legado (Pentium II/III/4, Core Duo, Atom - XFCE)
    LINUX /live/i686/vmlinuz-pae
    INITRD /live/i686/initrd-pae.img
    APPEND boot=live components live-media-path=/live/i686 quiet

LABEL i686_nopae
    MENU LABEL ETHEREUM 32-bit sem PAE (Pentium M Banias, VIA C3 - XFCE)
    LINUX /live/i686/vmlinuz-nopae
    INITRD /live/i686/initrd-nopae.img
    APPEND boot=live components live-media-path=/live/i686 quiet

LABEL retro_486
    MENU LABEL ETHEREUM Retro Pre-1999 (Intel 486, Pentium 1, AMD K6 - IceWM)
    LINUX /live/i486/vmlinuz
    INITRD /live/i486/initrd.img
    APPEND boot=live config live-media-path=/live/i486 quiet
ISOCFG

# 5. Configura menu UEFI (GRUB) para maquinas modernas e Macs
cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=5
set default=0

menuentry "ETHEREUM Linux 64-bit (Deteccao Automatica: Cinnamon / XFCE)" {
    linux /live/amd64/vmlinuz boot=live components live-media-path=/live/amd64 quiet
    initrd /live/amd64/initrd.img
}

menuentry "ETHEREUM Linux 32-bit Legado (XFCE + ZRAM)" {
    linux /live/i686/vmlinuz-pae boot=live components live-media-path=/live/i686 quiet
    initrd /live/i686/initrd-pae.img
}

menuentry "ETHEREUM Linux Retro Pre-1999 (i486 / IceWM)" {
    linux /live/i486/vmlinuz boot=live config live-media-path=/live/i486 quiet
    initrd /live/i486/initrd.img
}
GRUBCFG

# 6. Gera a ISO hibrida final bootavel em BIOS e UEFI
ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
[ -f "$ISOHDPFX" ] || ISOHDPFX="/usr/lib/syslinux/mbr/isohdpfx.bin"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "ETHEREUM_ALLINONE" \
    -isohybrid-mbr "$ISOHDPFX" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    -output "$FINAL_ISO" \
    "$ISO_ROOT"

echo "===================================================="
echo "SUCESSO! ISO completa gerada em: $FINAL_ISO"
echo "===================================================="
