output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db.name
}

output "dockerhub_secret_arn" {
  value = aws_secretsmanager_secret.placeholder["dockerhub"].arn
}

output "github_secret_arn" {
  value = aws_secretsmanager_secret.placeholder["github"].arn
}

output "jenkins_secret_arn" {
  value = aws_secretsmanager_secret.jenkins.arn
}

output "secret_names" {
  description = "key => secret name, for the host env file."
  value = merge(
    {
      db      = aws_secretsmanager_secret.db.name
      jenkins = aws_secretsmanager_secret.jenkins.name
    },
    { for k, s in aws_secretsmanager_secret.placeholder : k => s.name },
  )
}
