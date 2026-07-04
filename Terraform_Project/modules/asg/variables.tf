
variable "asg_name" {
  description = "Auto Scaling Group 이름 (접두어)"
  type        = string
}

variable "vpc_zone_identifier" {
  description = "ASG가 배포될 프라이빗 서브넷 ID 목록"
  type        = list(string)
}

variable "launch_template_id" {
  description = "EC2 인스턴스용 Launch Template ID"
  type        = string
}

variable "launch_template_version" {
  description = "Launch Template 버전"
  type        = string
  default     = "$Latest"
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
  default     = "app-instance"
}

variable "alb_target_group_bluegreen_arn" {
  description = "ASG 인스턴스에 부여할 Name 태그 값"
  type        = string
  default     = "app-instance"
}