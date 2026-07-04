variable "env" {
  description = "배포 환경 이름 (dev, prod 등)"
  type        = string
}

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
