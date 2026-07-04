output "asg_name" {
  description = "생성된 Auto Scaling Group의 이름"
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "생성된 Auto Scaling Group의 ARN"
  value       = aws_autoscaling_group.this.arn
}
