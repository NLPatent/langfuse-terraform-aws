# Private path from Metabase to ClickHouse.
#
# Metabase reads ClickHouse over HTTP on port 8123. The AWS Load Balancer
# Controller publishes that port on an internal NLB with IP targets, which is
# the supported way to reach Fargate pods from a peered VPC. The Langfuse
# ClusterIP service stays as it is, and native port 9000 is not published.
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.7/guide/service/nlb/
# https://www.metabase.com/docs/latest/databases/connections/clickhouse

resource "aws_security_group" "clickhouse_metabase" {
  count = length(var.metabase_clickhouse_client_cidrs) > 0 ? 1 : 0

  name        = "${var.name}-clickhouse-metabase"
  description = "Internal load balancer for Metabase access to ClickHouse HTTP"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = var.metabase_clickhouse_client_cidrs
    content {
      description = "ClickHouse HTTP from Metabase"
      from_port   = 8123
      to_port     = 8123
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "ClickHouse HTTP to Langfuse pods"
    from_port   = 8123
    to_port     = 8123
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  tags = merge(local.cost_tags, {
    Name = "${local.tag_name} ClickHouse Metabase"
  })
}

resource "kubernetes_service" "clickhouse_metabase" {
  count = length(var.metabase_clickhouse_client_cidrs) > 0 ? 1 : 0

  metadata {
    name      = "clickhouse-metabase"
    namespace = kubernetes_namespace.langfuse.metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"                                = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                     = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"                              = "internal"
      "service.beta.kubernetes.io/aws-load-balancer-name"                                = "${var.name}-clickhouse-metabase"
      "service.beta.kubernetes.io/aws-load-balancer-security-groups"                     = aws_security_group.clickhouse_metabase[0].id
      "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "true"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"                = "HTTP"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"                    = "/ping"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"                    = "8123"
      "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"            = "Service=${local.cost_tags.Service}"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      app = "${helm_release.langfuse_v2.name}-clickhouse"
    }
    port {
      name        = "http"
      port        = 8123
      target_port = 8123
      protocol    = "TCP"
    }
  }

  wait_for_load_balancer = true

  lifecycle {
    precondition {
      condition     = length("${var.name}-clickhouse-metabase") <= 32
      error_message = "The ClickHouse load balancer name ${var.name}-clickhouse-metabase is longer than the 32 characters AWS allows."
    }
  }

  depends_on = [
    helm_release.langfuse_v2,
    helm_release.aws_load_balancer_controller,
  ]
}
