variable "domain_name" {
  type = string
}

variable "env" {
  description = "환경 이름 (예: dev, stage, prod)"
  type        = string
}

variable "alb_name" {
  description = "ALB 이름"
  type        = string
}

variable "subnet_ids" {
  description = "ALB를 배포할 퍼블릭 서브넷 ID 목록"
  type        = list(string)
}

variable "security_group_ids" {
  description = "ALB에 적용할 보안 그룹 ID 목록"
  type        = list(string)
}

variable "vpc_id" {
  description = "ALB 대상 그룹 생성을 위한 VPC ID"
  type        = string
}

variable "target_group_name" {
  description = "ALB 대상 그룹 이름"
  type        = string
}


variable "alb_dns_acm_certificate_arn" {
  type = string
}

# variable "alb_logs_bucket_name" {
#   type = string
#   default = "koco-alb-logs"
# }