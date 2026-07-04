
variable "security_group_db_sg_id" {
  description = "db 보안 그룹 ID"
  type        = string
}

variable "subnet_private_id" {
  description = "인스턴스가 생성될 프라이빗 서브넷 ID"
  type        = string
}

variable "db_server_ami" {
  description = "db 서버 ami"
  type        = string
}

variable "db_server_instance_type" {
  description = "db 서버 인스턴스 타입"
  type        = string
}

variable "db_server_private_ip" {
  description = "db 서버 고정 프라이빗 아이피"
  type        = string
}

variable "db_server_key_name" {
  description = "db 서버 키"
  type        = string
}

variable "db_server_user_data" {
  description = "db 서버 키"
  type        = string
}

variable "db_server_tags" {
  description = "db 서버 태그"
  type        = map(string)
}

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