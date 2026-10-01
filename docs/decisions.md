# Design decisions

## 1. kind, and a CI job that builds everything from scratch

**Decision.** The lab runs on kind (Kubernetes in Docker). The `e2e` workflow creates a fresh cluster on every push, installs every component, and runs `scripts/test.sh`.

**Why.** A networking lab that only "should work" is not worth much. The CI run is the proof: if a version bump or a manifest change breaks the path, the badge goes red.

## 2. Cilium as CNI and kube-proxy replacement

**Decision.** kind starts without its default CNI and without kube-proxy. Cilium provides pod networking, Service load balancing (eBPF), LoadBalancer IPs (LB IPAM), L2 announcements and network policy, including L7 (HTTP) rules. Hubble is on for flow visibility.

**Why.** One component for the data path, and the same one enforces policy. Without kube-proxy, Cilium has to reach the API server directly, which is why `k8sServiceHost` points at the kind control-plane container.

## 3. Envoy Gateway for north-south, Gateway API only

**Decision.** Envoy Gateway implements the Gateway API. Cilium's own Gateway API support is switched off, so there is exactly one controller for Gateways.

**Why.** Gateway API separates roles cleanly: the platform team owns the `Gateway` (listeners, TLS, which namespaces may attach), application teams own their `HTTPRoute`s. Here only namespaces labelled `gateway-access=true` can attach routes.

Envoy Gateway's extensions cover what HTTPRoute alone does not: the `BackendTrafficPolicy` adds a local rate limit, and the `EnvoyProxy` resource sets the proxy replica count and Service type.

## 4. The same path from the inside and the outside

**Decision.** The Gateway's Service is a `LoadBalancer`; Cilium LB IPAM assigns an address from the top of the kind Docker subnet, and L2 announcements answer ARP for it.

**Why.** The Gateway gets a real address in its status, which external-dns publishes. On Linux that address is reachable from the host. On macOS and Windows, Docker's network is not routable from the host, so the tests use `kubectl port-forward` to the same Service. Both paths exercise the same listeners, certificates and routes.

## 5. DNS with RFC 2136 to an authoritative server

**Decision.** external-dns publishes the hostnames of HTTPRoutes into `lab.example` on an in-cluster BIND server, with RFC 2136 dynamic updates signed by a TSIG key (HMAC-SHA256). The zone only accepts signed updates and signed transfers.

**Why.** RFC 2136 with TSIG is how automation talks to most enterprise DNS (BIND, Infoblox; Windows DNS uses the same protocol with GSS-TSIG). The TXT ownership records (`heritage=external-dns,external-dns/owner=ingress-lab`) mean external-dns only changes records it created: a record created by hand next to them is never touched, and a route that is deleted takes its record with it (`--policy=sync`).

**Secret handling.** The TSIG key is generated at install time (`openssl rand`) into a Kubernetes Secret. It is never in the repository.

## 6. Certificates from cert-manager

**Decision.** A self-signed issuer creates a lab CA; a CA issuer signs a `*.lab.example` wildcard certificate for the Gateway, renewed automatically 10 days before expiry.

**Why.** Shows the full chain without depending on the internet. In a real environment the CA issuer is replaced by ACME (Let's Encrypt with DNS-01, which can reuse the same RFC 2136 setup) or a corporate PKI; nothing else changes.

## 7. Zero trust inside the cluster

**Decision.**

- Default deny for ingress and egress in the `apps` namespace (plain Kubernetes NetworkPolicy, enforced by Cilium).
- DNS egress allowed explicitly.
- Only the Envoy proxies may reach the app, and only `GET` on `/`, `/version`, `/healthz` and `/readyz` (CiliumNetworkPolicy with HTTP rules). podinfo's `/env` exists, but the policy answers 403 before the request reaches it.
- The kubelet on the node may run the health probes.

**Why.** The gateway is not the only line of defence. Even a request that passes the gateway is checked again in front of the workload, and a pod elsewhere in the cluster cannot bypass the gateway at all.

## 8. Pinned versions in one file

**Decision.** All versions live in `scripts/versions.env`, and the kind node image is pinned by digest.

**Why.** Reproducible builds, and upgrades become one-line changes that CI validates.

## 9. Workloads hardened by default

**Decision.** The app and external-dns run as non-root, with a read-only root filesystem, no privilege escalation, all capabilities dropped and the RuntimeDefault seccomp profile. external-dns has read-only RBAC on exactly the resources it reads.

**Why.** It costs a few lines and removes the most common findings of a Kubernetes security review.
