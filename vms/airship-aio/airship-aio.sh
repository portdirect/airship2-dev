export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get -y --no-install-recommends install git docker.io ansible make
cd ${HOME}
git clone https://opendev.org/airship/airshipctl.git ${HOME}/airshipctl
cd ${HOME}/airshipctl
git fetch https://review.opendev.org/airship/airshipctl refs/changes/74/705874/17
git checkout FETCH_HEAD
echo "primary ansible_connection=local" > "${HOME}/ansible_hosts"
tee ${HOME}/.ansible.cfg <<EOF
[defaults]
roles_path = ${HOME}/airshipctl/roles
EOF
tee ${HOME}/ansible_vars.yaml <<EOF
---
serve_dir: /srv/iso
serve_port: 8099
local_src_dir: "${HOME}/airshipctl"
ansible_user: root
site_name: "test-bootstrap"
remote_work_dir: "${HOME}/airshipctl"
zuul:
  executor:
    log_root: "$(mktemp -d)"
  project:
    src_dir: "${HOME}/airshipctl"
EOF
cd ${HOME}/airshipctl
SCRATCH=$(mktemp)
mv roles/libvirt-install/tasks/main.yaml "${SCRATCH}"
tac "${SCRATCH}" | sed '/meta: reset_connection/I,+1 d' | tac > roles/libvirt-install/tasks/main.yaml
sudo ansible-playbook \
  -i "${HOME}/ansible_hosts" \
  --extra-vars=@${HOME}/ansible_vars.yaml \
  "playbooks/airship-airshipctl-build-gate.yaml"
sudo bash -c 'echo security_driver = \"none\" >> /etc/libvirt/qemu.conf'
sudo systemctl restart libvirtd
sudo ansible-playbook \
  -i "${HOME}/ansible_hosts" \
  --extra-vars=@${HOME}/ansible_vars.yaml \
  "playbooks/airship-airshipctl-test-runner.yaml"