# Route53 Hosted Zone 정보
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

data "aws_region" "current" {}

resource "aws_cloudfront_origin_access_identity" "frontend_oai" {
  comment = "OAI for frontend S3 access"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Frontend SPA with ALB API routing"
  default_root_object = var.default_root_object

  aliases = [
    var.domain_name, 
    "www.${var.domain_name}"
  ]

  # S3 정적 호스팅
  origin {
    domain_name = "${var.s3_bucket_name}.s3.${data.aws_region.current.name}.amazonaws.com"
    origin_id   = "S3-${var.s3_bucket_name}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.frontend_oai.cloudfront_access_identity_path
    }
  }

  # SpringBoot
  origin {
    domain_name = var.alb_dns_name #alb dns 이름이 아니라 api.koco.click 또는 api.ktbkoco.com 으로 설정해야 함
    origin_id   = "ALB-Spring"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # OAuth 요청 (ALB로 라우팅)
  ordered_cache_behavior {
    path_pattern     = "/oauth/*"
    target_origin_id = "ALB-Spring"

    allowed_methods       = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods        = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # SpringBoot 요청
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = "ALB-Spring"

    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Unity WebGL 게임 라우팅 (예: /game/*)
  ordered_cache_behavior {
    path_pattern     = "/game/*"
    target_origin_id = "S3-${var.s3_bucket_name}"

    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }



  # 정적 파일 기본 처리
  default_cache_behavior {
    target_origin_id       = "S3-${var.s3_bucket_name}"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/${var.default_root_object}"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/${var.default_root_object}"
    error_caching_min_ttl = 0
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # cloudFront WAF 연결
  web_acl_id = var.waf_web_acl_id

  tags = {
    Name = "frontend-distribution"
  }
}

# Route 53
resource "aws_route53_record" "cdn_root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name            # "ktbkoco.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cdn_www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"   # "www.ktbkoco.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
