terraform {
  required_version = ">= 1.6"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }

  # ---------------------------------------------------------------------------
  # REMOTE STATE — enable this AFTER running scripts/bootstrap-tfstate.sh once.
  #
  # It is commented out deliberately: `terraform init` fails if the bucket and
  # lock table do not exist yet, which is a confusing first experience. Create
  # them, then uncomment, then re-run `terraform init -migrate-state`.
  #
  # State encryption is not optional here. Terraform state stores generated
  # database passwords in PLAINTEXT. Whoever can read the state bucket can read
  # your database credentials.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "REPLACE-tfstate-bucket"
  #   key            = "ha-web-platform/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
