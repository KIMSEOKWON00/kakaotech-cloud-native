# openvpn 인스턴스 생성
resource "aws_instance" "openvpn" {
    ami                         = var.openvpn_ami
    instance_type               = var.openvpn_instance_type
    subnet_id                   = var.subnet_id
    vpc_security_group_ids      = var.vpc_security_group_ids
    associate_public_ip_address = var.associate_public_ip_address
    key_name                    = var.openvpn_key_name
    source_dest_check           = false

    metadata_options {
    http_tokens   = "optional"     
    http_endpoint = "enabled"      # 메타데이터 사용 가능
    }

    tags = var.openvpn_tags
}