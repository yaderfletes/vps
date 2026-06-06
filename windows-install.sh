#!/bin/bash

# ============================================
# VERIFICACIÓN DE ENTORNO
# ============================================


# ============================================
# ACTUALIZACIÓN E INSTALACIÓN DE PAQUETES
# ============================================
apt update -y && apt upgrade -y
apt install grub2 wimtools ntfs-3g gdisk parted wimlib-imagex rsync -y

# ============================================
# CÁLCULO DEL TAMAÑO DEL DISCO (MÉTODO SEGURO)
# ============================================
disk_size_bytes=$(blockdev --getsize64 /dev/sda)
disk_size_mb=$((disk_size_bytes / 1024 / 1024))

if [ $disk_size_mb -lt 10000 ]; then
    echo "ERROR: Disco demasiado pequeño o no detectado correctamente"
    exit 1
fi

# Calcular 25% del disco para cada partición
part_size_mb=$((disk_size_mb / 4))

echo "Tamaño del disco: ${disk_size_mb}MB"
echo "Tamaño de cada partición: ${part_size_mb}MB"

# ============================================
# CREACIÓN DE PARTICIONES (UNA SOLA VEZ)
# ============================================
sgdisk -o /dev/sda                    # Limpia tabla anterior
sgdisk -n 1:2048:+${part_size_mb}MB -t 1:0700 /dev/sda
sgdisk -n 2:0:+${part_size_mb}MB -t 2:0700 /dev/sda

partprobe /dev/sda
sleep 5

# ============================================
# FORMATEO NTFS
# ============================================
mkfs.ntfs -Q -f /dev/sda1
mkfs.ntfs -Q -f /dev/sda2

# ============================================
# MONTAJE DE PARTICIONES
# ============================================
mkdir -p /mnt
mount /dev/sda1 /mnt || { echo "ERROR montando /dev/sda1"; exit 1; }

mkdir -p /root/windisk
mount /dev/sda2 /root/windisk || { echo "ERROR montando /dev/sda2"; exit 1; }

# ============================================
# INSTALACIÓN DE GRUB
# ============================================
grub-install --target=i386-pc --recheck --force --root-directory=/mnt /dev/sda

# Configuración de GRUB
mkdir -p /mnt/boot/grub
cat > /mnt/boot/grub/grub.cfg << 'EOF'
menuentry "Windows Installer" {
    insmod ntfs
    insmod part_gpt
    search --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF

# ============================================
# DESCARGA DE WINDOWS ISO
# ============================================
cd /root/windisk

wget -O win10.iso --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    "https://bit.ly/4aCjkM2"

# ============================================
# MONTAJE Y COPIA DE WINDOWS
# ============================================
mkdir -p winfile
mount -o loop win10.iso winfile

rsync -avz --progress winfile/* /mnt/

umount winfile

# ============================================
# DESCARGA Y COPIADO DE VIRTIO DRIVERS
# ============================================
wget -O virtio.iso --user-agent="Mozilla/5.0" \
    "https://bit.ly/4d1g7Ht"

mkdir -p virtio_mount
mount -o loop virtio.iso virtio_mount

# Crear directorio para VirtIO dentro de la instalación de Windows
mkdir -p /mnt/sources/virtio

# Copiar drivers VirtIO
rsync -avz --progress virtio_mount/* /mnt/sources/virtio/

umount virtio_mount

# ============================================
# INTEGRACIÓN DE VIRTIO EN BOOT.WIM
# ============================================
cd /mnt/sources

# Crear archivo de comandos para wimlib-imagex
cat > cmd.txt << 'EOF'
add virtio /virtio_drivers
EOF

# Aplicar la integración al boot.wim (índice 2)
wimlib-imagex update boot.wim 2 < cmd.txt

echo "=========================================="
echo "SCRIPT COMPLETADO CON ÉXITO"
echo "Los drivers VirtIO han sido integrados"
echo "=========================================="
echo "Ejecuta 'reboot' para reiniciar e iniciar la instalación de Windows"
