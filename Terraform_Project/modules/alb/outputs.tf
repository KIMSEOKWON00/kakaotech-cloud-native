output "alb_arn" {
  description = "생성된 ALB의 ARN"
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "생성된 ALB의 DNS 이름"
  value       = aws_lb.this.dns_name
}

output "target_group_BlueGreen_arn" {
  description = "생성된 ALB BlueGreen 대상 그룹의 ARN"
  value       = aws_lb_target_group.BlueGreen.arn
}

output "target_group_BlueGreen_name" {
  description = "생성된 ALB BlueGrenn 대상 그룹의 name"
  value       = aws_lb_target_group.BlueGreen.name
}



output "alb_listener_https_arn" {
  description = "생성된 ALB 리스너의 ARN"
  value       = aws_lb_listener.https.arn
}

