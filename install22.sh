#!/bin/bash

apt update -y && apt upgrade -y

apt install grub2 wimtools ntfs-3g -y

#Get the disk size in GB and convert to MB
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))

#Fixed partition size for installer (15GB)
part_size_mb=15360  # 15GB en MB

#Create GPT partition table
parted /dev/sda --script -- mklabel gpt

#Create two partitions
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB ${disk_size_mb}MB

#Inform kernel of partition table changes
partprobe /dev/sda

sleep 30

partprobe /dev/sda

sleep 30

partprobe /dev/sda

sleep 30 

#Format the partitions
mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

#Add labels to partitions for easy identification
ntfslabel /dev/sda1 "WINDOWS_INSTALLER"
ntfslabel /dev/sda2 "WINDOWS_SYSTEM"

echo "NTFS partitions created"
echo "Partition 1 (Installer): 15GB - Label: WINDOWS_INSTALLER"
echo "Partition 2 (Rest of disk): $(($disk_size_mb - 15360))MB - Label: WINDOWS_SYSTEM"

echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda

mount /dev/sda1 /mnt

#Prepare directory for the Windows disk
cd ~
mkdir windisk

mount /dev/sda2 windisk

grub-install --root-directory=/mnt /dev/sda

#Edit GRUB configuration
cd /mnt/boot/grub
cat <<EOF > grub.cfg
menuentry "windows installer" {
	insmod ntfs
	search --set=root --file=/bootmgr
	ntldr /bootmgr
	boot
}

menuentry "Windows 10/11 (installed)" {
	insmod ntfs
	search --set=root --file=/Windows/Boot/EFI/bootmgfw.efi
	chainloader /Windows/Boot/EFI/bootmgfw.efi
}
EOF

cd /root/windisk

mkdir winfile

# Download Windows 10 ISO
wget -O win10.iso --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" https://archive.org/download/WSRV22VirtIO/Windows_Server_2022_con_VirtIO.iso

# Mount and copy Windows ISO contents
mount -o loop win10.iso winfile

rsync -avz --progress winfile/* /mnt

umount winfile

# Create a script to update GRUB after Windows installation
cat <<EOF > /root/update-grub-windows.sh
#!/bin/bash
# Run this script after installing Windows to update GRUB
mount /dev/sda1 /mnt
mount /dev/sda2 /mnt2
# Copy Windows EFI files if they exist
if [ -d "/mnt2/Windows/Boot/EFI" ]; then
    mkdir -p /mnt/EFI/Microsoft
    cp -r /mnt2/Windows/Boot/EFI/* /mnt/EFI/Microsoft/
    echo "Windows boot files copied to GRUB partition"
fi
umount /mnt
umount /mnt2
echo "GRUB updated! You can now boot Windows from GRUB menu."
EOF

chmod +x /root/update-grub-windows.sh

# Clean up
cd /
umount /mnt
umount /root/windisk

echo "================================================"
echo "Windows installation media prepared successfully!"
echo ""
echo "Partition 1 (/dev/sda1): 15GB - WINDOWS_INSTALLER"
echo "Partition 2 (/dev/sda2): $(($disk_size_mb - 15360))MB - WINDOWS_SYSTEM"
echo ""
echo "NEXT STEPS:"
echo "1. Reboot to start Windows installation"
echo "2. During Windows setup, select Partition 2 (WINDOWS_SYSTEM) to install Windows"
echo "3. After Windows installation, run: /root/update-grub-windows.sh"
echo "4. Reboot and you'll see both options in GRUB menu"
echo "================================================"
