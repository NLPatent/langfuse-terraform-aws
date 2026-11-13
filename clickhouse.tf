# Random password for ClickHouse
# Using a alphanumeric password to avoid issues with special characters on bash entrypoint
resource "random_password" "clickhouse_password" {
  length      = 64
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

# Chart 2 mounts /langfuse-v2 volumes from the root module. These chart 1
# access points and persistent volumes stay in AWS and Kubernetes. Terraform
# only stops tracking them, so a later plan cannot create a second set.
removed {
  from = aws_efs_access_point.clickhouse

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_efs_access_point.zookeeper

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume.clickhouse_data

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume.clickhouse_zookeeper

  lifecycle {
    destroy = false
  }
}