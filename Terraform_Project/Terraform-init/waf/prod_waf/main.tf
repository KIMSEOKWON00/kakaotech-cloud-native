provider "aws" {
  alias  = "virginia"
  region = "us-east-1"  # CloudFront에 WAF 연결 시 필수
}

########################################
# 1. 악성 IP 수동 차단용 IPSet
########################################
resource "aws_wafv2_ip_set" "blocked_ips" {
  provider           = aws.virginia                  # CloudFront용 WAF는 반드시 us-east-1
  name               = "blocked-ips-prod"                 # IPSet 이름
  description        = "Blocked IP list for malicious and VPN addresses PROD"
  scope              = "CLOUDFRONT"                  # ALB면 REGIONAL, CloudFront면 CLOUDFRONT
  ip_address_version = "IPV4"

  addresses = [

    # 🟥 악성 IP


    # 🟧 VPN 또는 프록시 의심 IP 대역 (예: NordVPN, Surfshark 등에서 알려진 대역)


    # 🟨 특정 국가(예: 러시아, 중국)의 대역 예시 (GeoMatch가 부족할 때 보완)


    # 🟩 봇/스크래퍼 (예: Cloudflare가 분류한 봇 IP 목록 중 일부)

  ]

  tags = {
    Purpose     = "ManualIPBlock"
    Environment = "prod"
  }
}


########################################
# 2. Web ACL 생성
########################################
resource "aws_wafv2_web_acl" "main" {
  provider = aws.virginia
  name     = "secure-waf-prod"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}  # 기본은 허용, 룰에 걸리면 차단
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "secureWAF-prod"
  }

  ########################################
  # 📌 Rule 1: IP Rate Limit
  ########################################
  rule {
    name     = "rate-limit-prod"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000         # 5분 동안 1000회 초과 IP 차단
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "rateLimit-prod"
    }
  }

  ########################################
  # 📌 Rule 2: IPSet 차단 – 블랙리스트 IP 수동 차단
  # aws_wafv2_ip_set.blocked_ips에 등록된 IP 또는 IP 대역에 대해 무조건 차단합니다.
  ########################################
  rule {
    name     = "block-bad-ips-prod"
    priority = 1
    action {
      block {}
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocked_ips.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "ipBlock-prod"
    }
  }

  ########################################
  # 📌 Rule 3: GeoMatch - 특정 국가 허용 (예: 한국만 허용)
  ########################################
  rule {
    name     = "allow-korea-prod"
    priority = 2
    action {
      allow {}
    }
    statement {
      geo_match_statement {
        country_codes = ["KR"]  # ISO 국가코드 사용
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "geoAllow-prod"
    }
  }

  ########################################
  # 📌 Rule 4: AWS Managed Rules (SQL/XSS 등 차단)
  # 초기에는 none {}으로 로그만 보고 문제 없으면 action { block {} }으로 전환해도 됩니다.
  ########################################
  rule {
    name     = "aws-managed-threats-prod"
    priority = 3
    override_action {
      none {}  # 탐지만 하고 차단은 안함 (처음에는 count 모드 추천)
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "awsManaged-prod"
    }

  }
}
