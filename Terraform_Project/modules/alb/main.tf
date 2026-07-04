# ALB용 ACM 인증서 발급 및 검증 (서울 리전)
data "aws_route53_zone" "main" {
  name         = var.domain_name 
  private_zone = false
}


####################################
# 1. ALB 생성 (인터넷-facing)
####################################
resource "aws_lb" "this" {
  name               = var.alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = var.security_group_ids
  subnets            = var.subnet_ids

  # access_logs {
  #   bucket  = var.alb_logs_bucket_name
  #   prefix  = "alb-logs/${var.environment}"
  #   enabled = true
  # }

  tags = {
    Environment = var.env
    Name        = var.alb_name
  }
}

####################################
# 1.1 route53 레코드 생성 
####################################

resource "aws_route53_record" "alb_root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"                 # "api.ktbkoco.com"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "alb_www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}


####################################
# 2. Target Groups (Blue & Green)
####################################
resource "aws_lb_target_group" "BlueGreen" {
  name        = var.target_group_name
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/actuator/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}


####################################
# 3. ALB Listener (http:포트 80)
#    - 기본은 tg-blue
#    - tg-green은 추가 리스너 룰로 연결
####################################
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# 4.5. ALB Listener: HTTPS(443) → 기본적으로 Blue TG로 포워드
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.alb_dns_acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.BlueGreen.arn
  }
}

