output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "생성된 퍼블릭 서브넷 ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "어플리케이션 인스턴스용 프라이빗 서브넷 ID 목록"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "데이터베이스 인스턴스용 프라이빗 서브넷 ID 목록"
  value       = aws_subnet.private_db[*].id
}

output "nat_gateway_ids" {
  description = "생성된 NAT 게이트웨이 ID 목록"
  value       = aws_nat_gateway.nat[*].id
}
