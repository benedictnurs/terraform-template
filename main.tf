################################
# Terraform & Provider Configuration
################################
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

################################
# Variable Definitions
################################

################ OCI  ################
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string } # PEM file for OCI API
variable "region" { type = string }        # e.g. "us-ashburn-1"
variable "compartment_ocid" { type = string } # usually your root compartment OCID
variable "ssh_public_key" { type = string }   # file("~/.ssh/id_rsa.pub")

variable "vm_username" {
  type        = string
  description = "The username for the new user on the VM."
  default     = "user"
}

variable "vm_password" {
  type        = string
  description = "The password for the new user on the VM."
  default     = "password"
  sensitive   = true
}


################ Cloudflare  ################
variable "cf_api_token" { type = string }
variable "cf_account_id" { type = string }
variable "cf_zone_id" { type = string } # "" if no custom domain
variable "domain" { type = string }     # "" for tunnel URL only

################ GitHub / Docker  ################
variable "github_token" {
  type        = string
  description = "PAT with read:packages and write:packages scopes."
  sensitive   = true
}
variable "github_owner" { type = string }
variable "repo_name" { type = string }
variable "docker_image" { type = string } # ghcr.io/<owner>/<repo>:latest

################################
# Provider Configuration
################################
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

provider "cloudflare" {
  api_token = var.cf_api_token
}

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

provider "random" {}

################################
# Networking (VCN + Subnet + IGW)
################################
resource "oci_core_vcn" "vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "backend-vcn"
  dns_label      = "backendvcn"
}

# Internet Gateway
resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "igw"
}

# Route Table
resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Subnet
resource "oci_core_subnet" "subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "backend-subnet"
  route_table_id             = oci_core_route_table.rt.id
  dns_label                  = "backend"
  prohibit_public_ip_on_vnic = false
}

################################
# Cloudflare Tunnel + DNS
################################
resource "random_password" "tunnel_secret" {
  length  = 32
  special = false
}

# Creates a Cloudflare Tunnel resource
resource "cloudflare_tunnel" "backend" {
  account_id = var.cf_account_id
  name       = "oci-backend"
  secret     = base64encode(random_password.tunnel_secret.result)
}

resource "cloudflare_record" "api_dns" {
  count   = var.domain == "" ? 0 : 1
  zone_id = var.cf_zone_id
  name    = "api"
  type    = "CNAME"
  content = cloudflare_tunnel.backend.cname
  proxied = true
}

# Added a resource to configure the tunnel's routing.
# This replaces the need to add a "Public Hostname" in the Cloudflare UI.
resource "cloudflare_tunnel_config" "backend_config" {
  account_id = var.cf_account_id
  tunnel_id  = cloudflare_tunnel.backend.id

  config {
    ingress_rule {
      hostname = "api.seshon.tech"
      service  = "http://localhost:8080"
    }

    # If does not match any hostname, return a 404 error
    ingress_rule {
      service = "http_status:404"
    }
  }
}

################################
# User-data (rendered with built-in templatefile)
################################
locals {
  user_data_script = <<-EOT
    #!/bin/bash
    set -e 

    useradd -m -s /bin/bash ${var.vm_username}
    echo '${var.vm_username}:${var.vm_password}' | chpasswd
    usermod -aG sudo ${var.vm_username}

    apt-get update -y
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker

    wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb
    cloudflared service install ${cloudflare_tunnel.backend.tunnel_token}
    systemctl start cloudflared

    echo "${var.github_token}" | docker login ghcr.io -u "${var.github_owner}" --password-stdin

    docker run -d --restart=always -p 8080:8080 ${var.docker_image}
  EOT
}

################################
# Compute Instance
################################
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "20.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "vm" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "backend-vm"

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.user_data_script)
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }
}

################################
# GitHub Actions workflow & secret
################################
locals {
  ci_workflow = <<-YAML
    name: Build & Push Docker
    on:
      push:
        branches: [main]
    permissions:
      contents: read
      packages: write
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: docker/setup-buildx-action@v3
          - uses: docker/login-action@v3
            with:
              registry: ghcr.io
              username: ${var.github_owner}
              password: $${{ secrets.GHCR_TOKEN }}
          - uses: docker/build-push-action@v5
            with:
              context: ./backend
              file: ./backend/Dockerfile
              push: true
              tags: ${var.docker_image}
  YAML
}

resource "github_repository_file" "ci" {
  repository          = var.repo_name
  file                = ".github/workflows/ci.yml"
  branch              = "main"
  content             = local.ci_workflow
  overwrite_on_create = true
  commit_message      = "Add CI workflow via Terraform"
}

resource "github_actions_secret" "ghcr" {
  repository      = var.repo_name
  secret_name     = "GHCR_TOKEN"
  plaintext_value = var.github_token
}

################################
# Outputs
################################
output "public_ip" { value = oci_core_instance.vm.public_ip }
output "tunnel_url" { value = "${cloudflare_tunnel.backend.id}.cfargotunnel.com" }
output "pretty_url" { value = try(cloudflare_record.api_dns[0].hostname, "") }