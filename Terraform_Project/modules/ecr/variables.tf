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
