# Kubernetes Ingress Lab

A complete north-south path on a local Kubernetes cluster, built and tested end to end on every push:

**DNS name → LoadBalancer IP → Envoy Gateway (TLS, routing, rate limit) → Cilium L7 policy → app**

![e2e](https://github.com/inigogonzalezgarcia/06-kubernetes-ingress-lab/actions/workflows/e2e.yml/badge.svg)

| Piece | What it does here |
|---|---|
| **kind** | Three-node cluster in Docker, without its default CNI and without kube-proxy |
| **Cilium** | CNI, eBPF kube-proxy replacement, LoadBalancer IPs (LB IPAM) with L2 announcements, network policy from L3 to HTTP, Hubble |
| **Envoy Gateway** | Gateway API: one shared `Gateway`, HTTP→HTTPS redirect, TLS termination, timeouts, local rate limit |
| **cert-manager** | Lab CA and an automatically renewed `*.lab.example` certificate |
| **external-dns** | Publishes every HTTPRoute hostname to an authoritative BIND server with RFC 2136 dynamic updates signed with TSIG |

> A hands-on lab built while learning Kubernetes networking in depth. All names are reserved (`lab.example`) and nothing here comes from a production environment.

## Run it

Requires Docker, kind, kubectl, Helm 3, openssl and Python 3.

```bash
git clone https://github.com/inigogonzalezgarcia/06-kubernetes-ingress-lab.git
cd 06-kubernetes-ingress-lab
bash scripts/up.sh      # builds everything (5-10 minutes the first time)
bash scripts/test.sh    # 9 end-to-end checks
bash scripts/down.sh    # removes the cluster
```

Versions are pinned in [`scripts/versions.env`](scripts/versions.env): Kubernetes 1.35, Cilium 1.20, Envoy Gateway 1.9, cert-manager 1.21, external-dns 0.23.

## What the tests prove

Output of `scripts/test.sh` in the [CI run](https://github.com/inigogonzalezgarcia/06-kubernetes-ingress-lab/actions/workflows/e2e.yml) on GitHub's Linux runners:

```
PASS  Gateway is programmed with address 172.18.255.241 (from the Cilium LB IPAM pool)
PASS  HTTP redirects to HTTPS (301 https://orders.lab.example:18080/)
PASS  HTTPS works with the lab CA and reaches the app
PASS  Certificate issued by cert-manager covers *.lab.example
PASS  L7 policy blocks /env through the gateway (403)
PASS  Pods outside the gateway cannot reach the app directly (connection dropped by policy)
PASS  Rate limit returned 429 for 10 of 40 requests
PASS  orders.lab.example resolves to the Gateway address 172.18.255.241
PASS  external-dns wrote a TXT ownership record next to the A record
INFO  reached https://orders.lab.example on 172.18.255.241 through Cilium L2 announcements
9 passed, 0 failed
```

## Security controls

- **Who may publish routes:** the Gateway only accepts HTTPRoutes from namespaces labelled `gateway-access=true`.
- **Default deny** for ingress and egress in the application namespace; DNS allowed explicitly.
- **L7 allow-list in front of the app:** only the Envoy proxies, only `GET` on four paths. The app's `/env` endpoint exists but is never reachable.
- **No bypass:** a pod elsewhere in the cluster cannot reach the app without going through the gateway.
- **Signed DNS changes:** the zone accepts updates and transfers only with the TSIG key, which is generated at install time and never committed. external-dns only touches records it owns (TXT registry).
- **Hardened workloads:** non-root, read-only root filesystem, no privilege escalation, all capabilities dropped, RuntimeDefault seccomp, read-only RBAC for external-dns.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): request path, components, Gateway API ownership model, policy matrix.
- [docs/decisions.md](docs/decisions.md): why each piece was chosen and how it fits with the others.
- [docs/runbook.md](docs/runbook.md): hands-on commands, Hubble, troubleshooting table.

## Related projects

- [07 · AWS Private Connectivity](https://github.com/inigogonzalezgarcia/07-aws-private-connectivity): the same ideas (private names, narrow access, one service at a time) with AWS PrivateLink and Terraform.
- [08 · Edge Health & SLO Monitor](https://github.com/inigogonzalezgarcia/08-edge-health-slo-monitor): DNS, TLS and HTTP probes with SLOs that can watch `orders.lab.example`.

## Roadmap

- Contribute back: documentation or a small fix to external-dns, Envoy Gateway or Cilium, based on what this lab surfaces.
- ACME DNS-01 certificates using the same RFC 2136 zone.
- Global rate limiting (Envoy Gateway with Redis) and per-client limits.
- Hubble flow export to an observability stack.

## Customisation and contact

Want a lab like this for your team, a review of an existing ingress setup, or help moving from Ingress to Gateway API? Get in touch:

- Email: [inigogonzalezgarcia@yahoo.es](mailto:inigogonzalezgarcia@yahoo.es)
- LinkedIn: [linkedin.com/in/igonzalez93](https://www.linkedin.com/in/igonzalez93)

## License

MIT
