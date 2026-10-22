terraform {
  backend "s3" {
    bucket       = "gsmyth-terraform"
    key          = "datasync-terraform/dev/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}