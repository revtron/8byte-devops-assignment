# One role + instance profile per host. Every role gets SSM core (Session
# Manager + SSM agent); the rest is the minimum each boot script and runtime
# needs.

locals {
  roles = toset(["management", "backend", "mon"])

  ssm_run_shell_document_arn = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name               = "${var.project}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json

  tags = { Name = "${var.project}-${each.key}" }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = local.roles

  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  for_each = local.roles

  name = "${var.project}-${each.key}"
  role = aws_iam_role.this[each.key].name
}

# management: Jenkins deploys via SSM to the backend host only, notifies via
# SNS, and reads the Docker Hub / GitHub / Jenkins secrets at boot.
data "aws_iam_policy_document" "management" {
  statement {
    sid     = "SendDeployCommandToBackend"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.backend.arn,
      local.ssm_run_shell_document_arn,
    ]
  }

  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  statement {
    sid     = "ReadCiSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.secret_arns["dockerhub"],
      var.secret_arns["github"],
      var.secret_arns["jenkins"],
    ]
  }
}

# backend: DB credentials for deploy.sh; GitHub token so the boot-time clone
# works for a private repo.
data "aws_iam_policy_document" "backend" {
  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.secret_arns["db"],
      var.secret_arns["github"],
    ]
  }
}

# mon: DB credentials for postgres_exporter, Jenkins secret (reused as the
# Grafana admin password), GitHub token for the clone, SNS for Alertmanager.
data "aws_iam_policy_document" "mon" {
  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.secret_arns["db"],
      var.secret_arns["jenkins"],
      var.secret_arns["github"],
    ]
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = {
    management = data.aws_iam_policy_document.management.json
    backend    = data.aws_iam_policy_document.backend.json
    mon        = data.aws_iam_policy_document.mon.json
  }

  name   = "${var.project}-${each.key}"
  role   = aws_iam_role.this[each.key].id
  policy = each.value
}
