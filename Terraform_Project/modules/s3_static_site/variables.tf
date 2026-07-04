variable "env" {
  description = "배포 환경 이름 (dev, prod 등)"
  type        = string      
}

variable "bucket_name" {
  description = "Frontend static hosting bucket name"
  type        = string
}

variable "cloudfront_oai_arn" {
  description = "CloudFront Origin Access Identity의 IAM ARN"
  type        = string
}
