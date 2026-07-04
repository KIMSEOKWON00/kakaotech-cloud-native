variable "vpc_id" {
  description = "VPC 전체 IP 범위"
  type        = string
}

variable "private_subnet_id" {
  description = "인스턴스가 생성될 서브넷"
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