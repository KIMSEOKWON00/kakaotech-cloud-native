resource "aws_s3_bucket" "frontend" {
  bucket = "${var.bucket_name}" 
  #force_destroy = false     # 버킷 비우기 없이 삭제 방지

  # lifecycle {
  #   prevent_destroy = true       # 실수로 삭제되는 것 방지
  # }
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowCloudFrontAccess",
        Effect    = "Allow",
        Principal = {
          AWS = var.cloudfront_oai_arn
        },
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })
}
