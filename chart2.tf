# Chart 2 needs cert-manager and the ClickHouse operator before the Langfuse release.
# webhook.securePort avoids the Fargate kubelet port (10250).

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.20.2"
  timeout          = var.helm_release_timeout

  set {
    name  = "crds.enabled"
    value = "true"
  }

  set {
    name  = "webhook.securePort"
    value = "10260"
  }

  # Adopt the release that is already installed. A values refresh here restarts
  # the webhook that the ClickHouse operator depends on.
  lifecycle {
    ignore_changes = all
  }

  depends_on = [aws_eks_fargate_profile.namespaces]
}

resource "helm_release" "clickhouse_operator" {
  name             = "clickhouse-operator"
  namespace        = "clickhouse-operator"
  create_namespace = true
  repository       = "oci://ghcr.io/clickhouse"
  chart            = "clickhouse-operator-helm"
  version          = "0.0.5"
  timeout          = var.helm_release_timeout

  lifecycle {
    ignore_changes = all
  }

  depends_on = [
    helm_release.cert_manager,
    aws_eks_fargate_profile.namespaces,
  ]
}
