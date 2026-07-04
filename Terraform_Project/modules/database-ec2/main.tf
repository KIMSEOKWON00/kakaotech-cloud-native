resource "aws_iam_role" "ec2_s3_access" {
  name = var.ec2_s3_access_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_access_policy" {
  name = var.s3_access_policy_name
  role = aws_iam_role.ec2_s3_access.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::koco-db-backup"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::koco-db-backup/*"
      }
    ]
  })
}


resource "aws_iam_instance_profile" "ec2_profile" {
  name = var.ec2_profile_name
  role = aws_iam_role.ec2_s3_access.name
}




resource "aws_instance" "mysql_server" {
  ami                    = var.db_server_ami
  instance_type          = var.db_server_instance_type
  subnet_id              = var.subnet_private_id
  private_ip             = var.db_server_private_ip
  vpc_security_group_ids = [var.security_group_db_sg_id]
  key_name               = var.db_server_key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  metadata_options {
    http_tokens   = "required"     # IMDSv2만 허용
    http_endpoint = "enabled"      # 메타데이터 사용 가능
  }

  user_data = base64encode(var.db_server_user_data)


  tags = var.db_server_tags
}