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

variable "iam_instance_profile_name" {
  description = "EC2 인스턴스에 연결할 IAM 인스턴스 프로파일 이름"
  type        = string
}

variable "security_group_ids" {
  description = "EC2 인스턴스에 적용할 보안 그룹 ID 목록"
  type        = list(string)
}
