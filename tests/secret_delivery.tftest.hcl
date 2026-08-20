mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
    }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

run "stores_additional_secret_without_rendering_it_in_helm_values" {
  command = plan

  variables {
    domain          = "langfuse.example.com"
    skip_dns_setup  = true
    certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    vpc_id          = "vpc-00000000000000000"
    private_subnet_ids = [
      "subnet-00000000000000001",
      "subnet-00000000000000002",
    ]
    public_subnet_ids = [
      "subnet-00000000000000003",
      "subnet-00000000000000004",
    ]

    additional_secret_data = {
      "auth-google-client-secret" = "test-oauth-client-secret"
    }

    additional_env = [
      {
        name = "AUTH_GOOGLE_CLIENT_SECRET"
        valueFrom = {
          secretKeyRef = {
            name = "langfuse"
            key  = "auth-google-client-secret"
          }
        }
      }
    ]
  }

  assert {
    condition     = kubernetes_secret.langfuse.data["auth-google-client-secret"] == "test-oauth-client-secret"
    error_message = "The additional OAuth value must be stored in the Langfuse Kubernetes Secret."
  }

  assert {
    condition = (
      strcontains(local.additional_env_values, "secretKeyRef") &&
      strcontains(local.additional_env_values, "auth-google-client-secret")
    )
    error_message = "The Helm release must reference the OAuth key through secretKeyRef."
  }

  assert {
    condition     = !strcontains(local.additional_env_values, "test-oauth-client-secret")
    error_message = "The OAuth value must not be rendered into Helm values."
  }
}
