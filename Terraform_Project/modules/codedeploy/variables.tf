variable "app_name" {
  description = "CodeDeploy 애플리케이션 이름"
  type        = string
}

variable "deployment_group_name" {
  description = "CodeDeploy 배포 그룹 이름"
  type        = string
}

variable "service_role_arn" {
  description = "CodeDeploy 배포에 사용할 IAM 역할 ARN"
  type        = string
}

variable "autoscaling_groups" {
  description = "배포 대상으로 사용할 Auto Scaling Group 이름 목록"
  type        = list(string)
}

variable "alb_listener_https_arn" {
  description = "alb_listener_arn"
  type        = string
}

variable "alb_target_group_name" {
  description = "코드디플로이와 연결될 대상그룹 이름"
  type = string
}


