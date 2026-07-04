############################################
# Variables (variables.tf)
############################################
variable "alb_logs_bucket_name" {
  description = "ALB 액세스 로그를 저장할 S3 버킷 이름"
  type        = string
  default     = "koco-alb-logs"
}

variable "environment" {
  description = "로그를 저장할 prefix에 사용되는 배포 환경 이름"
  type        = string
  default     = "dev"
}

############################################
# 1. S3 버킷 생성
############################################
resource "aws_s3_bucket" "alb_logs" {
  bucket = var.alb_logs_bucket_name

  # 운영 로그 보존 시 false 권장
  force_destroy     = false

  tags = {
    Name        = var.alb_logs_bucket_name
    Environment = var.environment
  }
}

############################################
# 2. Public Access Block 설정
############################################
resource "aws_s3_bucket_public_access_block" "alb_logs_block" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = false   # 버킷 정책을 허용하기 위해 반드시 false
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################################
# 3. S3 버킷 정책: ALB(elasticloadbalancing) access 로그 권한
############################################
resource "aws_s3_bucket_policy" "alb_logs_policy" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [

      # 1) ALB가 버킷 ACL을 조회할 수 있도록 허용
      {
        Sid       = "AllowGetBucketAcl"
        Effect    = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${aws_s3_bucket.alb_logs.id}"
      },

      # 2) ALB가 로그를 쓰는 경로(alb-logs/<environment>/*)에 대해 PutObject 및 PutObjectAcl 허용
      {
        Sid       = "AllowELBv2Logging"
        Effect    = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "arn:aws:s3:::${aws_s3_bucket.alb_logs.id}/alb-logs/${var.environment}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }

    ]
  })
}
