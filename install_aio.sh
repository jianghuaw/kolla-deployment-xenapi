#!/bin/bash -ex

################
# Note: If the deployment host was installed via XenRTcenter, please firstly enabled the base repository;
# and disable the XenRT repository.
#[root@localhost yum.repos.d]# pwd
#/etc/yum.repos.d
rename .orig '' Cen*
mv xenrt.repo xenrt.repo.bakup
#[root@localhost yum.repos.d]# ls
#CentOS-Base.repo  CentOS-Debuginfo.repo  CentOS-Media.repo    CentOS-Vault.repo  docker.repo  epel-testing.repo
#CentOS-CR.repo    CentOS-fasttrack.repo  CentOS-Sources.repo  docker-ce.repo     epel.repo    xenrt.repo.disable
######################
# install dependence
######################

yum install -y  epel-release
yum install  -y python-pip
pip install -U pip


yum install -y python-devel libffi-devel gcc openssl-devel libselinux-python


yum install -y ansible
curl -sSL https://get.docker.io | bash


# Create the drop-in unit directory for docker.service
mkdir -p /etc/systemd/system/docker.service.d

# Create the drop-in unit file
tee /etc/systemd/system/docker.service.d/kolla.conf <<-'EOF'
[Service]
MountFlags=shared
EOF


# Run these commands to reload the daemon
systemctl daemon-reload
systemctl restart docker


#pip install -U docker

# install NTP (not needed for AIO I guess)
yum install -y ntp
systemctl enable ntpd.service
systemctl start ntpd.service

# install kolla and kolla-ansible

pip install kolla-ansible kolla


# Copy the configuration files globals.yml and passwords.yml to /etc directory.
cp -r /usr/share/kolla-ansible/etc_examples/kolla /etc/kolla/
f
# copy the inventory files
cp /usr/share/kolla-ansible/ansible/inventory/* .


# generate password
kolla-genpwd
# update the admin passwd for easy usage
# /etc/kolla/passwords.yml
# keystone_admin_password: admin

######################################
# Create local Registry
######################################
# refer to: https://docs.openstack.org/project-deploy-guide/kolla-ansible/ocata/multinode.html
# Please note the default port: 5000 conflicts with the port used by keystone; so use another port.

################################################
# customize the image and service configuration
################################################
#XS_IP=10.71.64.46
XS_USER=root
XS_PASSWD=xenroot


# customize nova compute configure
mkdir -p /etc/kolla/config/nova

cat > /etc/kolla/config/nova/nova-compute.conf <<EOF
[DEFAULT]
disk_allocation_ratio = 10
host = jgourlay-nova
compute_driver = xenapi.XenAPIDriver

[xenserver]
ovs_integration_bridge = br-int
vif_driver = nova.virt.xenapi.vif.XenAPIOpenVswitchDriver
connection_password = $XS_PASSWD
connection_username = $XS_USER
connection_url = http://$XS_IP
EOF

# customize neutron configuration (here need change the ansible playbook to suppor the new service of neutron-openvswitch-agent-domu
mkdir -p  /etc/kolla/config/neutron/

cat >/etc/kolla/config/neutron/ml2_domu.ini <<EOF
[DEFAULT]
host = jgourlay-nova

[agent]
minimize_polling = False
tunnel_types = vxlan
root_helper_daemon = xenapi_root_helper
root_helper =

[ovs]
of_listen_address = 192.168.1.100
ovsdb_connection = tcp:$XS_IP:6640
integration_bridge = br-int
datapath_type = system
bridge_mappings =
tunnel_bridge = br-tun
local_ip = $XS_IP

[xenapi]
connection_password = $XS_PASSWD
connection_username = $XS_USER
connection_url = http://$XS_IP
EOF

#############################
# build images
#############################
(date; kolla-build -t source  --registry localhost:5010  --push neutron-openvswitch-agent-domu nova-compute; date) 2>&1 | tee -a new.build-images.log

# Deploy AIO OpenStack environment.
kolla-ansible prechecks

(date; kolla-ansible deploy -i all-in-one ; date) | tee -a deploy$$.log

###########################
# TODO: prepare dom0
###########################

kolla-ansible post-deploy
. /etc/kolla/admin-openrc.sh
cd /usr/share/kolla-ansible
./init-runonce

# create vhd glance; the default image is cow2 which is not supported by XenAPIDriver
wget http://ca.downloads.xensource.com/OpenStack/cirros-0.3.5-x86_64-disk.vhd.tgz
glance image-create --name=cirros-vhd-image  --visibility=public  --container-format=ovf --disk-format=vhd --property vm_mode=hvm --file cirros-0.3.5-x86_64-disk.vhd.tgz
