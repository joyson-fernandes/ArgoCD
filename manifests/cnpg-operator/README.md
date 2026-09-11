# CNPG CRDs — applied manually, not via ArgoCD

The `cnpg-operator` Application sets `crds.create: false` because ArgoCD
(even with `ServerSideApply=true`) reproducibly failed to install the
`Cluster`/`Pooler` CRDs — confirmed live on 2026-09-11:

```
CustomResourceDefinition.apiextensions.k8s.io "clusters.postgresql.cnpg.io"
is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

These are two of the largest CRDs in the ecosystem (huge OpenAPI schemas).
Genuine `kubectl apply --server-side` works fine; ArgoCD's own apply path
did not, for reasons not fully root-caused beyond "large CRD + ArgoCD is a
known rough edge in the CNPG community."

To install/upgrade the CRDs for a given chart version:

```bash
helm pull cnpg/cloudnative-pg --version <VERSION> --untar --untardir /tmp/cnpg-chart
helm template cnpg /tmp/cnpg-chart/cloudnative-pg --set crds.create=true \
  --show-only templates/crds/crds.yaml > /tmp/cnpg-crds.yaml
kubectl apply --server-side --force-conflicts -f /tmp/cnpg-crds.yaml
rm -rf /tmp/cnpg-chart /tmp/cnpg-crds.yaml
```

Do this once per CNPG chart version bump in `apps/cnpg-operator.yaml`'s
`targetRevision` — CRDs change infrequently, so this isn't a real ongoing
maintenance burden.
