variable "s3_bucket_name" {
  description = "정적 웹사이트 호스팅용 S3 버킷 이름"
  type        = string
}

variable "default_root_object" {
  description = "CloudFront 기본 루트 객체 (보통 index.html)"
  type        = string
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name for /api traffic"
}

variable "domain_name" {
  type    = string
}

variable "acm_certificate_arn" {
  type = string
}

variable "waf_web_acl_id" {
  type = string
}