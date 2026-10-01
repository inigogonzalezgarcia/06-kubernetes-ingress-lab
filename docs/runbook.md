# Runbook

## Requirements

Docker, [kind](https://kind.sigs.k8s.io/), kubectl, Helm 3, openssl and Python 3. About 6 GB of free memory for Docker.

## Build, test, remove

```bash
bash scripts/up.sh        # 5-10 minutes the first time (image pulls)
bash scripts/test.sh      # end-to-end checks, exit code 0 when everything passes
bash scripts/down.sh      # deletes the cluster
```

`up.sh` can be re-run; it skips what already exists.

## Try things by hand

```bash
# Reach the gateway through a port-forward (works everywhere)
svc=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=lab -o name)
kubectl -n envoy-gateway-system port-forward "$svc" 18443:443 &
kubectl -n cert-manager get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
curl --cacert ca.crt --resolve orders.lab.example:18443:127.0.0.1 https://orders.lab.example:18443/
curl --cacert ca.crt --resolve orders.lab.example:18443:127.0.0.1 https://orders.lab.example:18443/env   # 403

# Watch policy verdicts with Hubble
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace apps --last 20

# See the DNS records external-dns created
kubectl run dig -n dns --rm -it --restart=Never --image=nicolaka/netshoot:v0.13 -- \
  dig +short @bind.dns.svc.cluster.local orders.lab.example
```

Add a second app: deploy it in `apps`, create an HTTPRoute for `name.lab.example` attached to the `lab` Gateway, and within a few seconds external-dns publishes the name.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Nodes `NotReady` after creating the cluster | Normal until Cilium is installed (there is no CNI before it). If it stays: `kubectl -n kube-system get pods -l k8s-app=cilium`, then the agent logs. |
| Gateway not `Programmed` | `kubectl -n gateway describe gateway lab`. Usually the certificate Secret is missing (`kubectl get certificate -A`) or the Service has no address (`kubectl get ciliumloadbalancerippool`). |
| Route not attached | `kubectl -n apps describe httproute orders`: check `Accepted` and `ResolvedRefs`. A namespace without `gateway-access=true` is refused by the listener. |
| 503 from the gateway | Backend endpoints: `kubectl -n apps get endpointslices`. Then policy: `hubble observe --namespace apps --verdict DROPPED`. |
| 403 on a path you expected to work | It is not in the L7 allow-list in `manifests/60-network-policies.yaml`. |
| Name does not resolve | `kubectl -n dns logs deploy/external-dns`: TSIG errors mean the key in the Secret and in BIND differ; "no records to update" means the route is not attached to the Gateway. |

`bash scripts/diagnose.sh` prints all of the above in one go; CI runs it automatically when a run fails.
