output "codedeploy_app_name" {
  description = "생성된 CodeDeploy 애플리케이션 이름"
  value       = aws_codedeploy_app.was_app.name
}

output "codedeploy_deployment_group_name" {
  description = "생성된 CodeDeploy 배포 그룹 이름"
  value       = aws_codedeploy_deployment_group.was_dg.deployment_group_name
}
