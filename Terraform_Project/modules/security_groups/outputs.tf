output "openvpn_sg_id" {
  description = "OpenVPN 서버 보안 그룹 ID"
  value       = aws_security_group.openvpn_sg.id
}

output "alb_sg_id" {
  description = "ALB 보안 그룹 ID"
  value       = aws_security_group.alb_sg.id
}

output "app_sg_id" {
  description = "애플리케이션 서버 보안 그룹 ID"
  value       = aws_security_group.app_sg.id
}

output "db_sg_id" {
  description = "RDS 전용 보안 그룹 ID"
  value       = aws_security_group.db_sg.id
}
