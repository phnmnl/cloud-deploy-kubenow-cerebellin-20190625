#!/usr/bin/env bash
set -e

# set pwd (to make sure all variable files end up in the deployment reference dir)
mkdir -p $PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE
cd $PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE

# presetup (generate key kubeadm token etc.)
$PORTAL_APP_REPO_FOLDER'/bin/pre-setup'
export TF_VAR_kubeadm_token=$(cat $PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/kubeadm_token')
export PRIVATE_KEY=$PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/vre.key'
export TF_VAR_ssh_key=$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE'/vre.key.pub'

#
# hardcoded params
#

# gce and ostack
export TF_VAR_KuberNow_image="kubenow-v020a1"
# workaround: -the credentials are provided as an environment variable, but KubeNow terraform
# scripts need a file. Creates an credentialsfile from the environment variable
echo $GOOGLE_CREDENTIALS > $PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/gce_credentials_file.json'
export TF_VAR_gce_credentials_file=$PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/gce_credentials_file.json'

# aws
export TF_VAR_kubenow_image_id="ami-1db87872"

# gce and aws
export TF_VAR_master_disk_size="50"
export TF_VAR_node_disk_size="50"
export TF_VAR_edge_disk_size="50"

# read cloudflare credentials from the cloned submodule private repo
source $PORTAL_APP_REPO_FOLDER'/'phenomenal-cloudflare/cloudflare_token_phenomenal.cloud.sh
export TF_VAR_cf_subdomain=$TF_VAR_cluster_prefix
domain=$TF_VAR_cf_subdomain'.'$TF_VAR_cf_zone

# Deploy cluster with terraform
terraform get $KUBENOW_TERRAFORM_FOLDER
terraform apply --state=$PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/terraform.tfstate' $KUBENOW_TERRAFORM_FOLDER

# Provision nodes with ansible
export ANSIBLE_HOST_KEY_CHECKING=False
nodes_count=$(($TF_VAR_node_count+$TF_VAR_edge_count+1)) # +1 because master is also one node
ansible_inventory_file=$PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/inventory'

# deploy core stack
ansible-playbook -i $ansible_inventory_file \
                 --key-file $PRIVATE_KEY \
                 -e "nodes_count=$nodes_count" \
                 -e "cf_mail=$TF_VAR_cf_mail" \
                 -e "cf_token=$TF_VAR_cf_token" \
                 -e "cf_zone=$TF_VAR_cf_zone" \
                 -e "cf_subdomain=$TF_VAR_cf_subdomain" \
                 $PORTAL_APP_REPO_FOLDER'/KubeNow/playbooks/install-core.yml'

# wait for all pods in core stack to be ready
ansible-playbook -i $ansible_inventory_file \
                 --key-file $PRIVATE_KEY \
                 $PORTAL_APP_REPO_FOLDER'/playbooks/wait_for_all_pods_ready.yml'

# deploy jupyter
JUPYTER_PASSWORD_HASH=$( $PORTAL_APP_REPO_FOLDER'/bin/generate-jupyter-password-hash.sh' $TF_VAR_jupyter_password )
ansible-playbook -i $ansible_inventory_file \
                 -e "domain=$domain" \
                 -e "sha1_pass_jupyter=$JUPYTER_PASSWORD_HASH" \
                 --key-file $PRIVATE_KEY \
                 $PORTAL_APP_REPO_FOLDER'/playbooks/jupyter/main.yml'

# deploy galaxy
$PORTAL_APP_REPO_FOLDER'/bin/generate-galaxy-api-key'
galaxy_api_key=$(cat $PORTAL_DEPLOYMENTS_ROOT'/'$PORTAL_DEPLOYMENT_REFERENCE'/galaxy_api_key')
ansible-playbook -i $ansible_inventory_file \
                 -e "domain=$domain" \
                 -e "galaxy_admin_password=$TF_VAR_galaxy_admin_password" \
                 -e "galaxy_admin_email=$TF_VAR_galaxy_admin_email" \
                 -e "galaxy_api_key=$galaxy_api_key" \
                 --key-file $PRIVATE_KEY \
                 $PORTAL_APP_REPO_FOLDER'/playbooks/galaxy.yml'
                                 
# wait for jupyter notebook http response != Bad Gateway
jupyter_url="http://notebook.$domain"
ansible-playbook -i $ansible_inventory_file \
                 -e "name=jupyter-notebook" \
                 -e "url=$jupyter_url" \
                 $PORTAL_APP_REPO_FOLDER'/playbooks/wait_for_http_not_down.yml'
                 
# wait for galaxy http response 200 OK
galaxy_url="http://galaxy.$domain"
ansible-playbook -i $ansible_inventory_file \
                 -e "name=galaxy" \
                 -e "url=$galaxy_url" \
                 $PORTAL_APP_REPO_FOLDER'/playbooks/wait_for_http_ok.yml'
