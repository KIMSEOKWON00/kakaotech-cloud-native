# S3 버킷 생성
resource "aws_s3_bucket" "frontend_builds" {
  bucket = "prod-koco-frontend-backup"  # 전역 유일한 버킷 이름

  tags = {
    Name        = "PROD Koco Frontend Builds"
    Environment = "prod"  # 예: dev, prod
    Purpose     = "React frontend build artifacts"
  }
}

# 퍼블릭 접근 차단 설정
resource "aws_s3_bucket_public_access_block" "frontend_builds" {
  bucket = aws_s3_bucket.frontend_builds.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# (선택) 버전 관리: 빌드 덮어쓰기 이력 추적용
resource "aws_s3_bucket_versioning" "frontend_builds" {
  bucket = aws_s3_bucket.frontend_builds.id

  versioning_configuration {
    status = "Enabled"
  }
}
