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