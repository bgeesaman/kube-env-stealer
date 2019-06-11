# Kube-Env-Stealer

## TL;DR

If you can run a pod in GKE and the cluster isn't running [Metadata Concealment](https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata) or the newer implementation of [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity), you have a really good chance at becoming `cluster-admin` in under a minute.

DISCLAIMER: Only perform this on clusters you own and operate or are authorized to assess.  This code is presented "as-is" without warranty fit for a particular purpose.  Read the code and understand what it's doing before using.

Steps:

- Clone this repo.
- Thoroughly read the code and understand what it's doing first.
- A working and configured `kubectl` pointed at the desired GKE cluster.
- Ensure you have permissions to create a basic nginx pod.
- Run `./auto-exploit.sh`
- After 15-30 seconds, examine the contents of `cluster.tar`.
- Leverage the service account token JWTs for service accounts with higher permissions via kubectl.

## Background

GKE clusters with exposed `kube-env` attributes files via the metadata API URL are vulnerable to mass kubelet impersonation and cluster-wide secret extraction.  In most cases, this will expose enough information with which to escalate privileges within the cluster to "cluster-admin" via service account tokens stored within secrets that have those permissions.  Or, it may provide just enough permissions to run pods that mount the host filesystem and allow "escaping" to the underlying host.

Accessing the `kube-env` file can occur via the UI/gcloud if the user has "compute.instances.get" IAM permissions or if the metadata API is not blocked from being accessed by pods.  In practice, this is commonly accessible to many users in a GCP Project that aren't meant to be cluster "admins".

Accessing the `kube-env` attributes attached to the GCE instances acting as GKE worker nodes via curl from inside a running pod:

```bash
curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env
```

If you see the contents of a largish file with key value pairs, you're all set.  If you receive a message that this endpoint has been concealed, the GKE Metadata Proxy is doing its job.

The kubelet has certain special permissions needed in order to do its job.  It can get/list all pods in all namespaces, and it can get a secret if it knows the exact name and if the secret is attached to a pod running on itself.  Compromising one kubelet's credentials means a partial secret compromise.  But, if all kubelets are compromised, every secret currently in use by any pod is exposed.

The contents of `kube-env` are, among other things, the "bootstrap" certs needed for the kubelet to generate a keypair for the node.  The permissions granted to these bootstrap certs allow it to submit a Certificate Signing Request (CSR) to the API Server and download/use the auto-approved certificates.  So, with a little work, we can gain a valid set of certificates as that kubelet.  The problem is, the secrets we are looking for might be attached to a pod on another node, and our kubelet will get a 403 Forbidden when trying to get its contents as kubelets can only "see" secrets for pods scheduled on themselves.  So, if we can impersonate every kubelet in the cluster, we can iterate through and extract the secrets each kubelet can see.

This is possible because: 1) the bootstrap `kube-env` certs are available without authentication via the metadata URL and 2) the `kube-env` certs allow one to generate a CSR for any hostname. Thus, simply knowing all the hostnames of the nodes in the cluster is sufficient to be able to generate a second, valid kubelet keypair for each node if we have one node's bootstrap certificates.  As a nice bonus, the generation of a new keypair doesn't invalidate the keypair that the kubelet is using, so this process is non-disruptive.

## High-level Attack Steps

Assuming we have the ability to run a pod on a GKE node not running [Metadata Concealment](https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata) or [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity), we can run a script inside a pod of our choosing that performs the following steps:

- Verify we have the proper binaries used by this script
- Download the `kube-env` from the metadata API URL
- Source `kube-env` vars into our shell
- Extract the bootstrap certificates from `kube-env` vars
- Download the latest kubectl binary
- Obtain the hostname of the current node (needed for the CSR)
- Impersonate the local kubelet
  - Generate a openssl.cnf with this hostname inside
  - Generate a CSR file for this hostname
  - Generate a YAML object containing this CSR ready for
    submission to K8s for signing/approving
  - Submit the CSR YAML and retrieve the valid kubelet certificate
    for this hostname
  - Extract all the secrets that the kubelet can see for that 
    hostname/node 
- Grab a full JSON listing of all Pod specs in all namespaces
- Use the current kubelet's permissions to get the list of
  nodes in the cluster by name
- Loop through all other nodes, impersonate each kubelet and
  extract all the secrets each kubelet can access.
- Grab a concise listing of namespace, pod name, and secret name
  to make use of the secret contents easier.
- Configure kubectl to use a ServiceAccount `token` JWT by passing in `--token eyJ...` to `kubectl` commands.

## Troubleshooting

1. If you or the script is unable to reach the `kube-env` endpoint on the Metadata API because the "endpoint has been concealed", your only option is to try modifying `evil-pod.yaml` to add `hostNetwork: true` so that the pod runs on the underlying node's network and bypasses the Metadata Proxy.

## Cleanup

If you have `cluster-admin` permissions, you can _carefully_ list and delete the extra CSRs via kubectl.  You can tell which ones to delete based on the date of creation.  This is likely the only activity that is potentially dangerous to your cluster.  It's also fine to leave them in-place.

## References

Coincidentally, this "exploit" script was being worked on /the same week/ as [https://www.4armed.com/blog/hacking-kubelet-on-gke/](https://www.4armed.com/blog/hacking-kubelet-on-gke/) wrote this great write-up (right before KubeCon 2018 NA) unbeknownst to me.  That said, I didn't want to release it immediately to allow for better GKE defaults/options to be available.  Now that Workload Identity is available and deprecates/incorporates the Metadata Concealment Proxy and several months have passed, the prevention mechanisms are readily available.

To see the more about real-world attacks that leveraged the metadata to escalate privileges inside a GKE cluster, watch [Shopify’s $25k Bug Report, and the Cluster Takeover That Didn’t Happen - Greg Castle and Shane Lawrence](https://www.youtube.com/watch?v=2XCm7vveU5A).
