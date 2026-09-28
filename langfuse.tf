locals {
  inbound_cidrs_csv = join(",", var.ingress_inbound_cidrs)
  langfuse_values   = <<EOT
langfuse:
  salt:
    secretKeyRef:
      name: langfuse
      key: salt
  nextauth:
    url: "https://${var.domain}"
    secret:
      secretKeyRef:
        name: langfuse
        key: nextauth-secret
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: ${aws_iam_role.langfuse_irsa.arn}
  image:
    tag: "${var.langfuse_image_tag}"
  # Resource configuration for production workloads
  resources:
    limits:
      cpu: "${var.langfuse_cpu}"
      memory: "${var.langfuse_memory}"
    requests:
      cpu: "${var.langfuse_cpu}"
      memory: "${var.langfuse_memory}"
  # The Web container needs slightly increased initial grace period on Fargate
  web:
    replicas: ${var.langfuse_web_replicas}
    livenessProbe:
      initialDelaySeconds: 60
    readinessProbe:
      initialDelaySeconds: 60
  worker:
    replicas: ${var.langfuse_worker_replicas}
postgresql:
  deploy: false
  host: ${aws_rds_cluster.postgres.endpoint}:5432
  auth:
    username: langfuse
    database: langfuse
    existingSecret: langfuse
    secretKeys:
      userPasswordKey: postgres-password
clickhouse:
  deploy: true
  # Use the password chart 2 already created. Do not point this at the chart 1
  # secret: that password is different, and leaving this empty lets an upgrade
  # generate a new one.
  auth:
    existingSecret: langfuse-v2-clickhouse-auth
    existingSecretKey: password
  cluster:
    replicas: ${var.clickhouse_replicas}
    resources:
      limits:
        cpu: "${var.clickhouse_cpu}"
        memory: "${var.clickhouse_memory}"
      requests:
        cpu: "${var.clickhouse_cpu}"
        memory: "${var.clickhouse_memory}"
    storage:
      className: ${kubernetes_storage_class.efs_langfuse.metadata[0].name}
      size: 100Gi
  keeper:
    replicas: ${var.clickhouse_replicas}
    resources:
      limits:
        cpu: "${var.clickhouse_keeper_cpu}"
        memory: "${var.clickhouse_keeper_memory}"
      requests:
        cpu: "${var.clickhouse_keeper_cpu}"
        memory: "${var.clickhouse_keeper_memory}"
    storage:
      className: ${kubernetes_storage_class.efs_langfuse.metadata[0].name}
      size: 20Gi
redis:
  deploy: false
  host: ${aws_elasticache_replication_group.redis.primary_endpoint_address}
  auth:
    existingSecret: langfuse
    existingSecretPasswordKey: redis-password
  tls:
    enabled: true
s3:
  deploy: false
  bucket: ${aws_s3_bucket.langfuse.id}
  region: ${data.aws_region.current.id}
  forcePathStyle: false
  eventUpload:
    prefix: "events/"
  batchExport:
    prefix: "exports/"
  mediaUpload:
    prefix: "media/"
EOT

  additional_env_values = length(var.additional_env) == 0 ? "" : <<EOT
langfuse:
  additionalEnv:
%{for env in var.additional_env~}
    - name: ${env.name}
%{if env.value != null~}
      value: "${env.value}"
%{endif~}
%{if env.valueFrom != null~}
      valueFrom:
%{if env.valueFrom.secretKeyRef != null~}
        secretKeyRef:
          name: ${env.valueFrom.secretKeyRef.name}
          key: ${env.valueFrom.secretKeyRef.key}
%{endif~}
%{if env.valueFrom.configMapKeyRef != null~}
        configMapKeyRef:
          name: ${env.valueFrom.configMapKeyRef.name}
          key: ${env.valueFrom.configMapKeyRef.key}
%{endif~}
%{endif~}
%{endfor~}
EOT

  ingress_values    = <<EOT
langfuse:
  ingress:
    # The existing ALB ingress is owned by kubernetes_ingress_v1.langfuse.
    # Chart 2 must not create a second ingress: this cluster has no ALB group,
    # so a new ingress would create a new load balancer and break DNS.
    enabled: false
    className: alb
    annotations:
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}, {"HTTPS":443}]'
      alb.ingress.kubernetes.io/scheme: ${var.alb_scheme}
      alb.ingress.kubernetes.io/target-type: 'ip'
      alb.ingress.kubernetes.io/ssl-redirect: '443'
      alb.ingress.kubernetes.io/inbound-cidrs: ${local.inbound_cidrs_csv}
      alb.ingress.kubernetes.io/certificate-arn: ${local.certificate_arn}
    hosts:
%{for host in concat([var.domain], var.additional_ingress_hosts)~}
    - host: ${host}
      paths:
      - path: /
        pathType: Prefix
%{endfor~}
EOT
  encryption_values = var.use_encryption_key == false ? "" : <<EOT
langfuse:
  encryptionKey:
    secretKeyRef:
      name: ${kubernetes_secret.langfuse.metadata[0].name}
      key: encryption_key
EOT

  # We could also consider excluding the following tables on opt-out:
  # <query_log remove="1"/>
  # <processors_profile_log remove="1"/>
  # <part_log remove="1"/>
  # <query_views_log remove="1"/>
  # <asynchronous_insert_log remove="1"/>
  # <query_metric_log remove="1"/>
  # <error_log remove="1"/>
}

resource "kubernetes_namespace" "langfuse" {
  metadata {
    name = "langfuse"
  }
}

resource "random_bytes" "salt" {
  # Should be at least 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> SALT
  length = 32
}

resource "random_bytes" "nextauth_secret" {
  # Should be at least 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> NEXTAUTH_SECRET
  length = 32
}

resource "random_bytes" "encryption_key" {
  count = var.use_encryption_key ? 1 : 0
  # Must be exactly 256 bits (32 bytes): https://langfuse.com/self-hosting/configuration#core-infrastructure-settings ~> ENCRYPTION_KEY
  length = 32
}

resource "kubernetes_secret" "langfuse" {
  metadata {
    name      = "langfuse"
    namespace = kubernetes_namespace.langfuse.metadata[0].name
  }

  data = merge(var.additional_secret_data, {
    "redis-password"      = random_password.redis_password.result
    "postgres-password"   = random_password.postgres_password.result
    "salt"                = random_bytes.salt.base64
    "nextauth-secret"     = random_bytes.nextauth_secret.base64
    "clickhouse-password" = random_password.clickhouse_password.result
    "encryption_key"      = var.use_encryption_key ? random_bytes.encryption_key[0].hex : ""
  })
}

# The chart 1.x release stays in the cluster so its ClickHouse and ZooKeeper
# remain available. Drop it from state without uninstalling it.
removed {
  from = helm_release.langfuse

  lifecycle {
    destroy = false
  }
}

resource "helm_release" "langfuse_v2" {
  name       = "langfuse-v2"
  namespace  = kubernetes_namespace.langfuse.metadata[0].name
  repository = "oci://ghcr.io/langfuse/langfuse-k8s/charts"
  chart      = "langfuse"
  version    = var.langfuse_helm_chart_version

  timeout = var.helm_release_timeout

  values = compact([
    local.langfuse_values,
    local.ingress_values,
    local.encryption_values,
    local.additional_env_values,
  ])

  depends_on = [
    kubernetes_namespace.langfuse,
    aws_iam_role.langfuse_irsa,
    aws_iam_role_policy.langfuse_s3_access,
    aws_eks_fargate_profile.namespaces,
    kubernetes_storage_class.efs_langfuse,
    helm_release.clickhouse_operator,
    kubernetes_service_account.aws_load_balancer_controller,
    helm_release.aws_load_balancer_controller
  ]
}

resource "kubernetes_ingress_v1" "langfuse" {
  metadata {
    name      = "langfuse"
    namespace = kubernetes_namespace.langfuse.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\":80}, {\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/scheme"          = var.alb_scheme
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/inbound-cidrs"   = local.inbound_cidrs_csv
      "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
    }
  }

  spec {
    ingress_class_name = "alb"

    dynamic "rule" {
      for_each = concat([var.domain], var.additional_ingress_hosts)
      content {
        host = rule.value
        http {
          path {
            path      = "/"
            path_type = "Prefix"
            backend {
              service {
                name = "${helm_release.langfuse_v2.name}-web"
                port {
                  name = "http"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.langfuse_v2]
}
