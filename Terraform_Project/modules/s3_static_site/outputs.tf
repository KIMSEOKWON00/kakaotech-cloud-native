output "dns_name" {
    value = aws_s3_bucket.frontend.bucket_domain_name
}
output "s3_bucket_name" {
  description = "정적 웹사이트 호스팅용 S3 버킷 이름"
  value       = aws_s3_bucket.frontend.bucket
}
