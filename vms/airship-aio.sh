
VM_NAME=airship-aio

sudo virsh destroy ${VM_NAME}
sudo virsh undefine ${VM_NAME}
sudo rm -rv /var/lib/libvirt/images/${VM_NAME}.qcow2 /var/lib/libvirt/boot/${VM_NAME}_config.iso

sudo qemu-img create -f qcow2 -o \
    backing_file=/var/lib/libvirt/images/base/bionic-server-cloudimg-amd64.qcow2 \
    /var/lib/libvirt/images/${VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${VM_NAME}.qcow2 +250G

sudo genisoimage -o /var/lib/libvirt/boot/${VM_NAME}_config.iso -V cidata -r -J ./airship-aio/meta-data ./airship-aio/network-config ./airship-aio/user-data

sudo virt-install --connect qemu:///system \
         --os-variant ubuntu18.04 \
         --name ${VM_NAME} \
         --memory 131072 \
         --memorybacking hugepages=on \
         --network bridge=bridge0 \
         --network network=default \
         --cpu host-passthrough \
         --vcpus 16,cpuset=4-7,12-32 \
         --import \
         --disk path=/var/lib/libvirt/images/${VM_NAME}.qcow2 \
         --disk path=/var/lib/libvirt/boot/${VM_NAME}_config.iso,device=cdrom \
         --nographics \
         --noautoconsole

sudo virsh domifaddr ${VM_NAME}

ssh ubuntu@$(sudo virsh domifaddr ${VM_NAME} --interface vnet1 | awk '/vnet1/ { print $NF ; exit}' | awk -F '/' '{ print $1 }')