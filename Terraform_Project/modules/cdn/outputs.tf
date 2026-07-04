output "cloudfront_oai_arn" {
  description = "IAM ARN of the CloudFront Origin Access Identity"
  value       = aws_cloudfront_origin_access_identity.frontend_oai.iam_arn
}