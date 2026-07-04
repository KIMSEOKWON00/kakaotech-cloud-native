output "codedeploy_role_arn" {
  description = "CodeDeploy IAM 역할 ARN"
  value       = aws_iam_role.codedeploy_role.arn
}

output "ec2_role_arn" {
  description = "EC2 인스턴스용 IAM 역할 ARN"
  value       = aws_iam_role.ec2_role.arn
}

output "ec2_instance_profile_name" {
  description = "EC2 인스턴스 프로파일 이름"
  value       = aws_iam_instance_profile.ec2_profile.name
}
