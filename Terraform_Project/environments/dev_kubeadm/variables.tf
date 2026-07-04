
#--------------------------------------
# 배포 환경 명시
#--------------------------------------
variable "env" {
  description = "배포 환경 이름 (dev, prod 등)"
  type        = string
}

#--------------------------------------
# network 모듈 variable 
#--------------------------------------
variable "vpc_cidr" {
  description = "VPC 전체 IP 범위"
  type        = string
}

variable "vpc_tag_name" {
  description = "VPC 태그 네임"
  type        = string
}

variable "igw_tag_name" {
  description = "인터넷게이트웨이 태그 네임"
  type        = string
}

variable "public_subnets" {
  description = "퍼블릭 서브넷 목록. 각 서브넷은 cidr과 availability_zone 값을 가진 객체입니다."
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "eip_nat_tag_name" {
  description = "NAT Elastic IP(고정 IP) 태그 네임"
  type        = string
}

variable "nat_gateway_tag_name" {
  description = "NAT 게이트웨이 태그 네임"
  type        = string
}

variable "public_rt_tag_name" {
  description = "퍼블릭 라우트테이블 태그 네임"
  type        = string
}

variable "private_app_subnets" {
  description = "어플리케이션 인스턴스용 프라이빗 서브넷 목록 (NAT 연결)"
  type = list(object({
    cidr = string
    az   = string
  }))
}



variable "private_db_subnets" {
  description = "데이터베이스 인스턴스용 프라이빗 서브넷 목록 (NAT 미연결)"
  type = list(object({
    cidr = string
    az   = string
  }))
}

#--------------------------------------
# s3_static_site 모듈 variable 
#--------------------------------------
variable "bucket_name" {
  description = "Frontend static hosting bucket name"
  type        = string
}

#--------------------------------------
# cdn 모듈 variable 
#--------------------------------------

variable "default_root_object" {
  description = "CloudFront 기본 루트 객체 (보통 index.html)"
  type        = string
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name for /api traffic"
}

variable "domain_name" {
  type    = string
}

variable "acm_certificate_arn" {
  type = string
}

variable "waf_web_acl_id" {
  type = string
}

#--------------------------------------
# ecr 모듈 variable 
#--------------------------------------
variable "repository_name" {
  description = "생성할 ECR 리포지토리 이름"
  type        = string
}

variable "image_tag_mutability" {
  description = "이미지 태그 변경 가능 여부 (MUTABLE 또는 IMMUTABLE)"
  type        = string
}

variable "scan_on_push" {
  description = "이미지 푸시 시 스캔 여부"
  type        = bool
}

variable "tags" {
  description = "리포지토리에 적용할 태그"
  type        = map(string)
}


#--------------------------------------
# iam 모듈 variable 
#--------------------------------------
variable "codedeploy_role_name" {
  description = "CodeDeploy IAM 역할 이름"
  type        = string
}

variable "ec2_role_name" {
  description = "EC2 인스턴스용 IAM 역할 이름"
  type        = string
}

variable "ec2_instance_profile_name" {
  description = "EC2 인스턴스 프로파일 이름"
  type        = string
}

variable "codedeploy_bluegreen_policy_name" {
  description = "사용자 정의 정책 codedeploy_bluegreen_policy 이름"
  type        = string
}

variable "ssm_parameter_read_name" {
  description = "사용자 정의 정책 ssm_parameter_read 이름"
  type        = string
}

#--------------------------------------
# codedeploy 모듈 variable 
#--------------------------------------
variable "app_name" {
  description = "CodeDeploy 애플리케이션 이름"
  type        = string
}

variable "deployment_group_name" {
  description = "CodeDeploy 배포 그룹 이름"
  type        = string
}


#--------------------------------------
# ec2 모듈 variable 
#--------------------------------------
variable "launch_template_name_prefix" {
  description = "lauch 템플릿 name prefix"
  type = string
}

variable "launch_template_image_id" {
  description = "lauch 템플릿 이미지 ami"
  type = string
}

variable "was_instance_type" {
  description = "EC2 인스턴스 타입 (예: t3.micro)"
  type        = string
}

variable "was_key_name" {
  description = "SSH 키 페어 이름"
  type        = string
}

variable "was_user_data" {
  description = "EC2 인스턴스 부팅 시 실행할 user_data 스크립트 (base64 인코딩 필요 없음)"
  type        = string
}

#--------------------------------------
# asg 모듈 variable 
#--------------------------------------
variable "asg_name" {
  description = "Auto Scaling Group 이름 (접두어)"
  type        = string
}

variable "launch_template_version" {
  description = "Launch Template 버전"
  type        = string
}

variable "desired_capacity" {
  description = "ASG 원하는 인스턴스 수"
  type        = number
}

variable "min_size" {
  description = "ASG 최소 인스턴스 수"
  type        = number
}

variable "max_size" {
  description = "ASG 최대 인스턴스 수"
  type        = number
}


variable "health_check_type" {
  description = "헬스체크 타입 (예: EC2, ELB)"
  type        = string
  default     = "ELB"
}

variable "health_check_grace_period" {
  description = "헬스체크 유예기간 (초)"
  type        = number
  default     = 300
}

variable "instance_tag_name" {
  description = "ASG 인스턴스에 부여할 Name 태그 값"
  type        = string
}

#--------------------------------------
# alb 모듈 variable 
#--------------------------------------
variable "alb_name" {
  description = "ALB 이름"
  type        = string
}

variable "target_group_name" {
  description = "ALB 대상 그룹 이름"
  type        = string
}


variable "alb_dns_acm_certificate_arn" {
  type = string
}

# variable "alb_logs_bucket_name" {
#   type = string
#   default = "koco-alb-logs"
# }

#--------------------------------------
# openvpn 모듈 variable 
#--------------------------------------
variable "openvpn_ami" {
  description = "OpenVPN Access Server 인스턴스에 사용할 AMI ID"
  type        = string
}
 
variable "openvpn_instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
}

variable "associate_public_ip_address" {
  description = "퍼블릭 IP 자동 할당 여부"
  type        = bool
}

variable "openvpn_key_name" {
  description = "key pair 이름"
  type = string
}

variable "openvpn_tags" {
  description = "리소스에 붙일 태그 맵"
  type        = map(string)
}

#--------------------------------------
# monitoring-ec2 모듈 variable 
#--------------------------------------
variable "monitoring_ec2_sd_role_name" {
  description = "monitoring_ec2_sd_role_name"
  type        = string
}

variable "monitoring_ec2_sd_policy_name" {
  description = "monitoring_ec2_sd_policy_name"
  type        = string
}

variable "monitoring_instance_profile_name" {
  description = "monitoring_instance_profile_name"
  type        = string
}

variable "monitoring_server_ami" {
  description = "모티터링 서버 ami"
  type        = string
}

variable "monitoring_server_instance_type" {
  description = "모티터링 서버 인스턴스 타입"
  type        = string
}

variable "monitoring_server_private_ip" {
  description = "모티터링 서버 고정 프라이빗 아이피"
  type        = string
}

variable "monitoring_server_key_name" {
  description = "모티터링 서버 키"
  type        = string
}

variable "monitoring_server_tags" {
  description = "모티터링 서버 태그"
  type        = map(string)
}

#--------------------------------------
# database-ec2 모듈 variable 
#--------------------------------------
variable "ec2_s3_access_name" {
  description = "ec2_s3_access_name"
  type        = string
}

variable "s3_access_policy_name" {
  description = "s3_access_policy_name"
  type        = string
}

variable "ec2_profile_name" {
  description = "ec2_profile_name"
  type        = string
}

variable "db_server_ami" {
  description = "모티터링 서버 ami"
  type        = string
}

variable "db_server_instance_type" {
  description = "모티터링 서버 인스턴스 타입"
  type        = string
}

variable "db_server_private_ip" {
  description = "모티터링 서버 고정 프라이빗 아이피"
  type        = string
}

variable "db_server_key_name" {
  description = "모티터링 서버 키"
  type        = string
}

variable "db_server_user_data" {
  description = "모티터링 서버 키"
  type        = string
}

variable "db_server_tags" {
  description = "모티터링 서버 태그"
  type        = map(string)
}