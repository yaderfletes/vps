#!/bin/bash

echo "=========================================="
echo "VERIFICANDO ENTORNO"
echo "=========================================="

# 1. Verificar que NO estamos en entorno overlay


# 2. Instalar paquetes necesarios (con manejo de errores)
echo "Instalando dependencias..."
apt update -y && apt upgrade -y

# Intentar diferentes nombres de paquete para wimlib
apt install -y grub2 wimtools ntfs-3g gdisk parted rsync || \
apt install -y grub2 wimutils ntfs-3g gdisk parted rsync || \
apt install -y grub2 ntfs-3g gdisk parted rsync

# Instalar wimlib-imagex desde fuente si no existe
if ! command -v wimlib-imagex &> /dev/null; then
    echo "wimlib-imagex no encontrado, instalando desde fuente..."
    apt install -y git build-essential libxml2-dev libssl-dev
    cd /tmp
    git clone https://github.com/msys2/wimlib.git
    cd wimlib
    ./configure --prefix=/usr
    make && make install
    cd /
fi

# 3. LIMPIAR EL DISCO COMPLETAMENTE (IMPORTANTE)
echo "=========================================="
echo "LIMPIANDO DISCO /dev/sda"
echo "=========================================="

# Desmontar todo lo que esté montado en /dev/sda
umount /dev/sda* 2>/dev/null
swapoff /dev/sda* 2>/dev/null

# Limpiar los primeros y últimos sectores del disco
dd if=/dev/zero of=/dev/sda bs=512 count=10000 status=progress
dd if=/dev/zero of=/dev/sda bs=512 seek=$(($(blockdev --getsz /dev/sda) - 10000)) count=10000 status=progress

# Crear tabla GPT limpia
sgdisk -Z /dev/sda           # Cero la tabla actual (ZAP)
sgdisk -o /dev/sda           # Nueva tabla GUID
partprobe /dev/sda
sleep 3

# 4. CÁLCULO DEL TAMAÑO
disk_size_bytes=$(blockdev --getsize64 /dev/sda)
disk_size_mb=$((disk_size_bytes / 1024 / 1024))
part_size_mb=$((disk_size_mb / 4))

echo "Tamaño del disco: ${disk_size_mb}MB"
echo "Tamaño de cada partición: ${part_size_mb}MB"

# 5. CREAR PARTICIONES
echo "=========================================="
echo "CREANDO PARTICIONES"
echo "=========================================="

# Usar sgdisk con fuerza (-g)
sgdisk -n 1:2048:+${part_size_mb}MB -t 1:0700 -c 1:"Windows_System" /dev/sda
sgdisk -n 2:0:+${part_size_mb}MB -t 2:0700 -c 2:"Windows_Data" /dev/sda

# Verificar que las particiones existen
if ! sgdisk -p /dev/sda | grep -q "/dev/sda1"; then
    echo "ERROR: No se pudo crear /dev/sda1"
    sgdisk -p /dev/sda
    exit 1
fi

partprobe /dev/sda
sleep 5

# 6. FORMATEAR NTFS
echo "=========================================="
echo "FORMATEANDO PARTICIONES"
echo "=========================================="

# Asegurar que no están montadas
umount /dev/sda1 2>/dev/null
umount /dev/sda2 2>/dev/null

# Formatear
mkfs.ntfs -Q -f /dev/sda1 -L "Windows_System"
mkfs.ntfs -Q -f /dev/sda2 -L "Windows_Data"

# 7. MONTAR PARTICIONES
echo "=========================================="
echo "MONTANDO PARTICIONES"
echo "=========================================="

mkdir -p /mnt
mount /dev/sda1 /mnt
if [ $? -ne 0 ]; then
    echo "ERROR montando /dev/sda1"
    exit 1
fi

mkdir -p /root/windisk
mount /dev/sda2 /root/windisk
if [ $? -ne 0 ]; then
    echo "ERROR montando /dev/sda2"
    exit 1
fi

echo "Particiones montadas exitosamente"

# 8. INSTALAR GRUB
echo "=========================================="
echo "INSTALANDO GRUB"
echo "=========================================="

mkdir -p /mnt/boot/grub
grub-install --target=i386-pc --recheck --force --root-directory=/mnt /dev/sda

# Configuración GRUB
cat > /mnt/boot/grub/grub.cfg << 'EOF'
set timeout=10
set default=0

menuentry "Instalar Windows Server 2022" {
    insmod ntfs
    insmod part_gpt
    search --set=root --file=/sources/setup.exe
    ntldr /bootmgr
    boot
}

menuentry "Instalar Windows (modo seguro)" {
    insmod ntfs
    insmod part_gpt
    set root=(hd0,1)
    chainloader +1
    boot
}
EOF

# 9. CONTINUAR CON EL RESTO (WINDOWS ISO + VIRTIO)
cd /root/windisk

echo "Descargando Windows ISO..."
wget -O win10.iso --user-agent="Mozilla/5.0" "https://bit.ly/4aCjkM2"

mkdir -p winfile
mount -o loop win10.iso winfile

echo "Copiando archivos de Windows..."
rsync -avz --progress winfile/* /mnt/

umount winfile

echo "Descargando VirtIO ISO..."
wget -O virtio.iso --user-agent="Mozilla/5.0" "https://bit.ly/4d1g7Ht"

mkdir -p virtio_mount
mount -o loop virtio.iso virtio_mount

mkdir -p /mnt/sources/virtio

echo "Copiando drivers VirtIO..."
rsync -avz --progress virtio_mount/* /mnt/sources/virtio/

umount virtio_mount

# 10. INTEGRAR VIRTIO EN BOOT.WIM
cd /mnt/sources

if [ -f boot.wim ]; then
    echo "Integrando VirtIO en boot.wim..."
    cat > cmd.txt << 'EOF'
add virtio /virtio_drivers
EOF
    wimlib-imagex update boot.wim 2 < cmd.txt
    echo "VirtIO integrado exitosamente"
else
    echo "ADVERTENCIA: boot.wim no encontrado"
    echo "Los drivers VirtIO están en /sources/virtio/"
fi

echo "=========================================="
echo "¡PROCESO COMPLETADO CON ÉXITO!"
echo "=========================================="
echo ""
echo "Ahora puedes:"
echo "1. Ejecutar 'reboot' para reiniciar"
echo "2. Arrancar desde /dev/sda"
echo "3. Los drivers VirtIO estarán disponibles"
echo ""
