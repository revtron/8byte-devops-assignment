data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

module "network" {
  source = "./modules/network"

  project  = var.project
  vpc_cidr = var.vpc_cidr
  azs      = var.azs
}

module "security" {
  source = "./modules/security"

  project    = var.project
  vpc_id     = module.network.vpc_id
  admin_cidr = var.admin_cidr
}

module "notifications" {
  source = "./modules/notifications"

  project     = var.project
  alert_email = var.alert_email
}

module "database" {
  source = "./modules/database"

  project            = var.project
  private_subnet_ids = module.network.private_subnet_ids
  rds_sg_id          = module.security.rds_sg_id
  instance_class     = var.db_instance_class
  allocated_storage  = var.db_allocated_storage
}

module "secrets" {
  source = "./modules/secrets"

  project     = var.project
  db_host     = module.database.address
  db_port     = module.database.port
  db_username = module.database.username
  db_password = module.database.password
}

# alb <-> compute reference each other (ALB DNS goes into user-data; the
# backend instance id goes into the target group attachment). That is fine:
# Terraform builds the graph per resource and no resource depends on itself.
module "alb" {
  source = "./modules/alb"

  project             = var.project
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  alb_sg_id           = module.security.alb_sg_id
  backend_instance_id = module.compute.backend_instance_id
  account_id          = local.account_id
}

module "compute" {
  source = "./modules/compute"

  project           = var.project
  region            = var.region
  public_subnet_id  = module.network.public_subnet_ids[0]
  private_subnet_id = module.network.private_subnet_ids[0]
  management_sg_id  = module.security.management_sg_id
  backend_sg_id     = module.security.backend_sg_id
  mon_sg_id         = module.security.mon_sg_id
  instance_types    = var.instance_types
  admin_public_key  = var.admin_public_key
  github_repo       = var.github_repo
  git_ref           = var.git_ref
  dockerhub_repo    = var.dockerhub_repo
  secret_names      = module.secrets.secret_names
  secret_arns = {
    db        = module.secrets.db_secret_arn
    dockerhub = module.secrets.dockerhub_secret_arn
    github    = module.secrets.github_secret_arn
    jenkins   = module.secrets.jenkins_secret_arn
  }
  sns_topic_arn = module.notifications.topic_arn
  alb_dns_name  = module.alb.alb_dns_name
  templates_dir = "${path.module}/templates"
}
