PRIVATE_KEY_FILE=""

chmod 0600 $PRIVATE_KEY_FILE

git clone https://github.com/kubernetes-sigs/kubespray.git

# install ansible
VENVDIR=kubespray-venv
KUBESPRAYDIR=kubespray
python3 -m venv $VENVDIR
source $VENVDIR/bin/activate
cd $KUBESPRAYDIR
pip install -r requirements.txt

# have access to local inventory

ansible-playbook -i ayo-local/inventory/inventory.ini cluster.yml -b -v --private-key=$PRIVATE_KEY_FILE