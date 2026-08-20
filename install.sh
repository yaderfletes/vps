#!/bin/bash

# Configurar DNS
echo "Configurando servidores DNS..."
cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF

echo "✅ DNS configurado"

# Actualizar sistema
echo "*** Update and Upgrade ***"
apt update -y && apt upgrade -y

# Instalar paquetes necesarios
echo "*** Installing required packages ***"
apt install -y dosfstools wimtools ntfs-3g grub-pc grub2-common rsync wget parted exfat-utils wimlib-imagex

# ========================================
# CONFIGURACIÓN DE PARTITIONES
# ========================================

echo "📌 Configurando particiones para Windows Server 2022..."

# 1. Formatear sda1 como FAT32 (PARTICIÓN DE BOOT - 500MB)
echo "🔧 Formateando /dev/sda1 como FAT32 (Boot partition)..."
mkfs.vfat -F32 /dev/sda1

# 2. Formatear sda2 como NTFS (PARTICIÓN DE DATOS - Resto del disco)
echo "🔧 Formateando /dev/sda2 como NTFS (Data partition)..."
mkfs.ntfs -f /dev/sda2

# ========================================
# MONTAR PARTITIONES
# ========================================

echo "📂 Montando particiones..."
umount /mnt 2>/dev/null
umount /root/windisk 2>/dev/null

# sda1 → Boot (FAT32) - Solo para GRUB
mount /dev/sda1 /mnt

# sda2 → Datos (NTFS) - Para todos los archivos de instalación
mkdir -p /root/windisk
mount /dev/sda2 /root/windisk

# ========================================
# INSTALAR GRUB EN sda1 (FAT32)
# ========================================

echo "🖥️ Instalando GRUB en /dev/sda1..."
grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/sda

# ========================================
# CONFIGURAR GRUB PARA APUNTAR A NTFS (sda2)
# ========================================

echo "⚙️ Configurando GRUB..."
mkdir -p /mnt/boot/grub

cat <<EOF > /mnt/boot/grub/grub.cfg
menuentry "Windows Server 2022 Installer" {
    insmod ntfs
    insmod part_gpt
    search --no-floppy --set=root --file=/WindowsSetup/bootmgr
    ntldr /WindowsSetup/bootmgr
    boot
}
EOF

# ========================================
# PREPARAR DIRECTORIOS EN NTFS
# ========================================

cd /root/windisk
mkdir -p WindowsSetup
mkdir -p winfile

# ========================================
# DESCARGAR WINDOWS SERVER 2022 ISO
# ========================================

echo "📥 Descargando Windows Server 2022 ISO..."
read -p "¿Usar URL por defecto? (Y/N): " use_default

if [[ "$use_default" == "Y" || "$use_default" == "y" ]]; then
    windows_url="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
else
    read -p "Ingresa URL del ISO: " windows_url
fi

echo "Descargando ISO (esto puede tomar varios minutos)..."
wget -O Windows.iso --progress=bar --user-agent="Mozilla/5.0" "$windows_url"

if [ ! -f "Windows.iso" ]; then
    echo "❌ ERROR: No se pudo descargar el ISO"
    echo "📌 Sube manualmente Windows.iso a /root/windisk/"
    read -p "Presiona Enter cuando hayas subido el archivo..."
fi

# ========================================
# MONTAR Y COPIAR ISO A NTFS
# ========================================

echo "📀 Montando ISO Windows Server 2022..."
mount -o loop Windows.iso winfile

echo "📋 Copiando archivos a /root/windisk/WindowsSetup/ (NTFS)..."
rsync -av --progress --no-perms --no-owner --no-group winfile/* /root/windisk/WindowsSetup/

umount winfile

# ========================================
# VERIFICAR BOOT.WIM EN NTFS
# ========================================

if [ -f "/root/windisk/WindowsSetup/sources/boot.wim" ]; then
    echo "✅ boot.wim encontrado en NTFS"
    ls -lh /root/windisk/WindowsSetup/sources/boot.wim
else
    echo "❌ ERROR: boot.wim no encontrado"
    exit 1
fi

# ========================================
# INSTALAR Y CONFIGURAR VIRTIO DRIVERS
# ========================================

echo "🔄 Descargando VirtIO drivers para Windows Server 2022..."
cd /root
apt install wimtools -y

wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso

mkdir -p virtio_mount
mount -o loop virtio-win.iso virtio_mount

# ========================================
# CORRECCIÓN: CREAR ESTRUCTURA DE CARPETAS PARA DRIVERS
# ========================================

echo "📁 Creando estructura de carpetas para drivers..."

# Directorio base para drivers
DRIVER_BASE="/root/windisk/WindowsSetup/sources/virtio_drivers"
mkdir -p "$DRIVER_BASE"

# Función para copiar drivers manteniendo estructura
copy_driver_with_structure() {
    local src_dir="$1"
    local dest_base="$2"
    local driver_name="$3"
    
    if [ -d "$src_dir" ]; then
        echo "  Copiando $driver_name..."
        # Crear subcarpeta para el driver
        mkdir -p "$dest_base/$driver_name"
        # Copiar todos los archivos manteniendo estructura
        cp -r "$src_dir"/* "$dest_base/$driver_name/" 2>/dev/null
        # También copiar archivos sueltos
        find "$src_dir" -type f -name "*.inf" -exec cp {} "$dest_base/$driver_name/" \; 2>/dev/null
        find "$src_dir" -type f -name "*.sys" -exec cp {} "$dest_base/$driver_name/" \; 2>/dev/null
        find "$src_dir" -type f -name "*.cat" -exec cp {} "$dest_base/$driver_name/" \; 2>/dev/null
        find "$src_dir" -type f -name "*.dll" -exec cp {} "$dest_base/$driver_name/" \; 2>/dev/null
    else
        echo "  ⚠️ No se encontró $driver_name"
    fi
}

echo "📦 Copiando drivers VirtIO para Server 2022 con estructura de carpetas..."

# 1. VIOSTOR - Driver SCSI principal
copy_driver_with_structure "virtio_mount/viostor/2k22/amd64" "$DRIVER_BASE" "viostor"
copy_driver_with_structure "virtio_mount/viostor/2k22/x86" "$DRIVER_BASE" "viostor_x86"

# 2. VIOSCSI - Driver SCSI específico (el que te faltaba)
copy_driver_with_structure "virtio_mount/vioscsi/2k22/amd64" "$DRIVER_BASE" "vioscsi"
copy_driver_with_structure "virtio_mount/vioscsi/2k22/x86" "$DRIVER_BASE" "vioscsi_x86"

# 3. NetKVM - Driver de red
copy_driver_with_structure "virtio_mount/NetKVM/2k22/amd64" "$DRIVER_BASE" "netkvm"
copy_driver_with_structure "virtio_mount/NetKVM/2k22/x86" "$DRIVER_BASE" "netkvm_x86"

# 4. Balloon - Driver de memoria
copy_driver_with_structure "virtio_mount/balloon/2k22/amd64" "$DRIVER_BASE" "balloon"
copy_driver_with_structure "virtio_mount/balloon/2k22/x86" "$DRIVER_BASE" "balloon_x86"

# 5. viorng - Driver de random
copy_driver_with_structure "virtio_mount/viorng/2k22/amd64" "$DRIVER_BASE" "viorng"
copy_driver_with_structure "virtio_mount/viorng/2k22/x86" "$DRIVER_BASE" "viorng_x86"

# 6. qxl - Driver de video
copy_driver_with_structure "virtio_mount/qxl/2k22/amd64" "$DRIVER_BASE" "qxl"
copy_driver_with_structure "virtio_mount/qxl/2k22/x86" "$DRIVER_BASE" "qxl_x86"

# 7. También copiar drivers para Windows 2019 (por compatibilidad)
copy_driver_with_structure "virtio_mount/viostor/2k19/amd64" "$DRIVER_BASE" "viostor_2k19"
copy_driver_with_structure "virtio_mount/vioscsi/2k19/amd64" "$DRIVER_BASE" "vioscsi_2k19"

umount virtio_mount
rm -rf virtio_mount

# ========================================
# VERIFICAR QUE LOS DRIVERS ESTÉN PRESENTES
# ========================================

echo ""
echo "📊 Verificando estructura de drivers:"
echo "----------------------------------------"
echo "Estructura de carpetas:"
ls -la "$DRIVER_BASE" | head -20

echo ""
echo "Buscando vioscsi.inf:"
find "$DRIVER_BASE" -name "vioscsi.inf" -type f

if [ -f "$DRIVER_BASE/vioscsi/vioscsi.inf" ]; then
    echo "✅ vioscsi.inf encontrado en su carpeta"
else
    echo "⚠️ vioscsi.inf no encontrado - verificando alternativas..."
    find "$DRIVER_BASE" -name "*.inf" | grep -i scsi
fi

# ========================================
# INYECTAR DRIVERS EN BOOT.WIM CON ESTRUCTURA
# ========================================

echo ""
echo "💉 Inyectando drivers en boot.wim y install.wim..."
cd /root/windisk/WindowsSetup/sources

# Ver índices del boot.wim
echo "📋 Información del boot.wim:"
wimlib-imagex info boot.wim | head -20

# CORRECCIÓN: Inyectar carpeta completa con estructura
echo "Inyectando drivers en boot.wim (todos los índices)..."

# Obtener el número de índices disponibles
num_indices=$(wimlib-imagex info boot.wim | grep -c "Image Index:" || echo "4")

for i in $(seq 1 $num_indices); do
    echo "  Inyectando en índice $i..."
    # Inyectar toda la carpeta con su estructura
    wimlib-imagex update boot.wim $i --command="add virtio_drivers /virtio_drivers" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "  ✅ Índice $i procesado correctamente"
    else
        echo "  ⚠️ No se pudo inyectar en índice $i"
    fi
done

echo "✅ Drivers inyectados en boot.wim"

# También inyectar en install.wim si existe
if [ -f "install.wim" ]; then
    echo "📦 Inyectando drivers en install.wim..."
    
    num_indices_install=$(wimlib-imagex info install.wim | grep -c "Image Index:" || echo "1")
    
    for i in $(seq 1 $num_indices_install); do
        echo "  Inyectando drivers en install.wim índice $i..."
        wimlib-imagex update install.wim $i --command="add virtio_drivers /virtio_drivers" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "  ✅ Índice $i procesado correctamente"
        fi
    done
    
    echo "✅ Drivers inyectados en install.wim"
fi

# ========================================
# CREAR AUTORUN CON RUTA CORRECTA
# ========================================

echo ""
echo "📝 Creando archivo de configuración para carga automática de drivers..."

# Crear autounattend.xml con las rutas correctas
cat > /root/windisk/WindowsSetup/autounattend.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <DiskConfiguration>
                <WillShowUI>OnError</WillShowUI>
            </DiskConfiguration>
            <EnableFirewall>false</EnableFirewall>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <DriverPaths>
                <PathAndCredentials wcm:keyValue="1">
                    <Path>X:\WindowsSetup\sources\virtio_drivers\vioscsi</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="2">
                    <Path>X:\WindowsSetup\sources\virtio_drivers\viostor</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="3">
                    <Path>X:\WindowsSetup\sources\virtio_drivers\netkvm</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="4">
                    <Path>X:\WindowsSetup\sources\virtio_drivers\balloon</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="5">
                    <Path>X:\WindowsSetup\sources\virtio_drivers\viorng</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
    </settings>
    <settings pass="offlineServicing">
        <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <DriverPaths>
                <PathAndCredentials wcm:keyValue="1">
                    <Path>%SystemDrive%\WindowsSetup\sources\virtio_drivers\vioscsi</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="2">
                    <Path>%SystemDrive%\WindowsSetup\sources\virtio_drivers\viostor</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="3">
                    <Path>%SystemDrive%\WindowsSetup\sources\virtio_drivers\netkvm</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="4">
                    <Path>%SystemDrive%\WindowsSetup\sources\virtio_drivers\balloon</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:keyValue="5">
                    <Path>%SystemDrive%\WindowsSetup\sources\virtio_drivers\viorng</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
    </settings>
</unattend>
EOF

echo "✅ autounattend.xml creado con rutas específicas"

# ========================================
# CREAR SCRIPT PARA CARGAR DRIVERS MANUALMENTE
# ========================================

cat > /root/windisk/WindowsSetup/load_drivers.cmd << 'EOF'
@echo off
echo Cargando drivers VirtIO...
echo.
echo Instalando VIOSCSI...
drvload X:\WindowsSetup\sources\virtio_drivers\vioscsi\vioscsi.inf
echo.
echo Instalando VIOSTOR...
drvload X:\WindowsSetup\sources\virtio_drivers\viostor\viostor.inf
echo.
echo Instalando NetKVM...
drvload X:\WindowsSetup\sources\virtio_drivers\netkvm\netkvm.inf
echo.
echo Instalando Balloon...
drvload X:\WindowsSetup\sources\virtio_drivers\balloon\balloon.inf
echo.
echo Instalando viorng...
drvload X:\WindowsSetup\sources\virtio_drivers\viorng\viorng.inf
echo.
echo ✅ Todos los drivers cargados!
echo.
pause
EOF

echo "✅ Script load_drivers.cmd creado para carga manual"

# ========================================
# VERIFICACIÓN FINAL
# ========================================

echo ""
echo "📊 Verificación final:"
echo "----------------------------------------"
echo "Estructura de drivers:"
tree -L 2 "$DRIVER_BASE" 2>/dev/null || ls -R "$DRIVER_BASE" | head -30

echo ""
echo "Archivos vioscsi encontrados:"
find "$DRIVER_BASE" -name "vioscsi*" -type f

echo ""
echo "Tamaño de install.wim:"
ls -lh install.wim 2>/dev/null || echo "install.wim no encontrado"

echo ""
echo "✅ INSTALACIÓN COMPLETA PARA WINDOWS SERVER 2022"
echo ""
echo "📌 Estructura de carpetas:"
echo "  virtio_drivers/"
echo "  ├── vioscsi/          ← Driver SCSI (¡el que te faltaba!)"
echo "  │   ├── vioscsi.inf"
echo "  │   ├── vioscsi.sys"
echo "  │   └── ..."
echo "  ├── viostor/          ← Driver SCSI alternativo"
echo "  ├── netkvm/           ← Driver de red"
echo "  ├── balloon/          ← Driver de memoria"
echo "  └── viorng/           ← Driver de random"
echo ""
echo "🔧 Si no detecta automáticamente:"
echo "  1. Presiona Shift+F10 durante la instalación"
echo "  2. Ejecuta: X:\WindowsSetup\load_drivers.cmd"
echo ""
echo "El sistema reiniciará en 10 segundos..."

sleep 1

# ========================================
# LIMPIEZA Y REINICIO
# ========================================

sync
umount /mnt 2>/dev/null
umount /root/windisk 2>/dev/null
sync
