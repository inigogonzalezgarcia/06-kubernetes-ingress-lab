#!/usr/bin/env bash
# Creates the whole lab on a local kind cluster. Safe to re-run.
# Needs: docker, kind, kubectl, helm, openssl, python3.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/versions.env
source scripts/versions.env

step() { printf '\n==> %s\n' "$*"; }

# Put pinned image names into a manifest and apply it.
apply() {
  sed -e "s|PODINFO_IMAGE|${PODINFO_IMAGE}|g" \
      -e "s|BIND_IMAGE|${BIND_IMAGE}|g" \
      -e "s|EXTERNAL_DNS_IMAGE|${EXTERNAL_DNS_IMAGE}|g" "$1" | kubectl apply -f -
}

step "kind cluster ${CLUSTER_NAME}"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config kind/cluster.yaml
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

step "Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"
helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null
helm upgrade --install cilium cilium/cilium --version "${CILIUM_VERSION}" \
  --namespace kube-system -f helm/cilium-values.yaml \
  --set k8sServiceHost="${CLUSTER_NAME}-control-plane" --wait --timeout 10m
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

step "LoadBalancer IP pool on the kind network"
subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
read -r lb_start lb_stop < <(python3 - "$subnet" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1])
last = net.broadcast_address
print(last - 14, last - 1)   # the top /28 of the network, minus the broadcast address
PY
)
echo "kind subnet ${subnet}: LoadBalancer range ${lb_start}-${lb_stop}"
sed -e "s/LB_START/${lb_start}/" -e "s/LB_STOP/${lb_stop}/" manifests/10-lb-ipam.yaml | kubectl apply -f -

step "cert-manager ${CERT_MANAGER_VERSION}"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout 10m

step "Envoy Gateway ${ENVOY_GATEWAY_VERSION} (installs the Gateway API CRDs too)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system --create-namespace --wait --timeout 10m
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

step "Namespaces, certificates, Gateway"
kubectl apply -f manifests/00-namespaces.yaml
kubectl apply -f manifests/20-certificates.yaml
kubectl -n cert-manager wait certificate/lab-ca --for=condition=Ready --timeout=2m
kubectl -n gateway wait certificate/lab-wildcard --for=condition=Ready --timeout=2m
kubectl apply -f manifests/30-gateway.yaml
kubectl -n gateway wait gateway/lab --for=condition=Programmed --timeout=5m

step "Application, routes, network policies"
apply manifests/40-app.yaml
kubectl apply -f manifests/50-routes.yaml
kubectl apply -f manifests/60-network-policies.yaml
kubectl -n apps rollout status deployment/orders --timeout=5m

step "DNS: BIND + external-dns"
if ! kubectl -n dns get secret tsig >/dev/null 2>&1; then
  secret=$(openssl rand -base64 32)
  kubectl -n dns create secret generic tsig \
    --from-literal=secret="${secret}" \
    --from-literal=tsig.key="key \"externaldns-key\" { algorithm hmac-sha256; secret \"${secret}\"; };"
fi
apply dns/bind.yaml
kubectl -n dns rollout status deployment/bind --timeout=5m
apply dns/external-dns.yaml
kubectl -n dns rollout status deployment/external-dns --timeout=5m

step "Done"
kubectl -n gateway get gateway lab
echo "Run scripts/test.sh to check every part of the path."
