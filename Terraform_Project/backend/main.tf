####################################
# 테라폼 상태저장을 aws s3와 DynamoDB로 관리하기 위한 설정 테라폼 실행 파일
# 이 파일을 통해 테라폼 상태를 관리하는 s3와 DynamoDB가 생성된다.
# 이 파일을 terraform apply 한 후 dev/main or prod/main 을 terraform apply 해야한다.
####################################

resource "aws_s3_bucket" "terraform_state" { 
  bucket = "koco-terraformstate"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "enabled" { 
  bucket = aws_s3_bucket.terraform_state.id 
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" { 
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_lock" {
  name         = "koco-terraformstate"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}