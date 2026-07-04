# S3 버킷 생성
resource "aws_s3_bucket" "codedeploy_artifacts" {
  bucket = "dev-koco-codedeploy-artifacts"  # 전역 유일해야 함

  tags = {
    Name        = "DEV Koco CodeDeploy Artifacts"
    Environment = "dev" # dev, stage, prod 중 택1
    Purpose     = "Store CodeDeploy deployment artifacts"
  }
}

# 퍼블릭 접근 차단 설정
resource "aws_s3_bucket_public_access_block" "codedeploy_artifacts" {
  bucket = aws_s3_bucket.codedeploy_artifacts.id

  block_public_acls       = true   # 퍼블릭 ACL 차단
  block_public_policy     = true   # 퍼블릭 정책 차단
  ignore_public_acls      = true   # 퍼블릭 ACL 무시
  restrict_public_buckets = true   # 퍼블릭 설정 자체 차단
}

# (선택) 버킷 버전 관리 - 필요 없다면 생략 가능
resource "aws_s3_bucket_versioning" "codedeploy_artifacts" {
  bucket = aws_s3_bucket.codedeploy_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}
