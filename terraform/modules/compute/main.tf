data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = data.aws_ssm_parameter.al2023.insecure_value

  # Shared by every host's user-data; role-specific keys are merged per instance.
  user_data_common = {
    project             = var.project
    region              = var.region
    admin_public_key    = var.admin_public_key
    github_repo         = var.github_repo
    git_ref             = var.git_ref
    dockerhub_repo      = var.dockerhub_repo
    db_secret_id        = var.secret_names["db"]
    dockerhub_secret_id = var.secret_names["dockerhub"]
    github_secret_id    = var.secret_names["github"]
    jenkins_secret_id   = var.secret_names["jenkins"]
    sns_topic_arn       = var.sns_topic_arn
    alb_dns             = var.alb_dns_name
    backend_private_ip  = var.backend_private_ip
    mon_private_ip      = var.mon_private_ip
    compose_version     = var.compose_version
  }

  user_data_template = "${var.templates_dir}/user_data.sh.tftpl"
}

resource "aws_instance" "backend" {
  ami                    = local.ami_id
  instance_type          = var.instance_types["backend"]
  subnet_id              = var.private_subnet_id
  private_ip             = var.backend_private_ip
  vpc_security_group_ids = [var.backend_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.this["backend"].name

  user_data = templatefile(local.user_data_template, merge(local.user_data_common, {
    role                = "backend"
    backend_instance_id = ""
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Containers (Alertmanager, postgres_exporter, Jenkins jobs) reach IMDS
    # through the docker bridge, which costs one extra hop.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_sizes["backend"]
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-backend"
    Role = "backend"
  }

  lifecycle {
    # A newer AL2023 AMI must not silently replace the host on the next apply.
    ignore_changes = [ami]
  }
}

resource "aws_instance" "mon" {
  ami                    = local.ami_id
  instance_type          = var.instance_types["mon"]
  subnet_id              = var.private_subnet_id
  private_ip             = var.mon_private_ip
  vpc_security_group_ids = [var.mon_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.this["mon"].name

  user_data = templatefile(local.user_data_template, merge(local.user_data_common, {
    role                = "mon"
    backend_instance_id = ""
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Containers (Alertmanager, postgres_exporter, Jenkins jobs) reach IMDS
    # through the docker bridge, which costs one extra hop.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_sizes["mon"]
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-mon"
    Role = "mon"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "management" {
  ami                    = local.ami_id
  instance_type          = var.instance_types["management"]
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.management_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.this["management"].name

  # The EIP is attached after the instance exists; an auto-assigned public IP
  # gives cloud-init internet access during that window.
  associate_public_ip_address = true

  user_data = templatefile(local.user_data_template, merge(local.user_data_common, {
    role                = "management"
    backend_instance_id = aws_instance.backend.id
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Containers (Alertmanager, postgres_exporter, Jenkins jobs) reach IMDS
    # through the docker bridge, which costs one extra hop.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_sizes["management"]
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-management"
    Role = "management"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "management" {
  domain   = "vpc"
  instance = aws_instance.management.id

  tags = { Name = "${var.project}-management-eip" }
}
