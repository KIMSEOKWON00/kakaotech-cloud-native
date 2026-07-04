# Launch Template 생성
resource "aws_launch_template" "app_lt" {
  name_prefix   = var.launch_template_name_prefix
  image_id      = var.launch_template_image_id

  instance_type = var.was_instance_type 
  key_name      = var.was_key_name         # SSH 접근을 위한 키페어

  iam_instance_profile {
    name = var.iam_instance_profile_name    # EC2에 연결할 IAM Role
  }

  metadata_options {
    http_tokens   = "required"     # IMDSv2만 허용
    http_endpoint = "enabled"      # 메타데이터 사용 가능
  }

  user_data = base64encode(var.was_user_data)       # 초기 부팅 시 실행할 스크립트

  vpc_security_group_ids = var.security_group_ids       # 보안 그룹 설정


  tag_specifications {
    resource_type = "instance"
    tags = {
      Role = "WAS"  
      Name = "AppInstance"
    }
  }
}


