################  OCI  ################
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string } # PEM file for OCI API
variable "region" { type = string }           # e.g. "us-ashburn-1"
variable "compartment_ocid" { type = string } # usually your root compartment OCID
variable "ssh_public_key" { type = string }   # file("~/.ssh/id_rsa.pub")

################  Cloudflare  ################
variable "cf_api_token" { type = string }
variable "cf_account_id" { type = string }
variable "cf_zone_id" { type = string } # "" if no custom domain
variable "domain" { type = string }     # "" for tunnel URL only

################  GitHub / Docker  ################
variable "github_token" { type = string } # PAT: repo + write:packages
variable "github_owner" { type = string }
variable "repo_name" { type = string }
variable "docker_image" { type = string } # ghcr.io/<owner>/<repo>:latest