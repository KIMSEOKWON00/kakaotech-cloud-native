########################################
# CodeDeploy IAM 역할 생성 및 정책 첨부
########################################

resource "aws_iam_role" "codedeploy_role" {
  name = var.codedeploy_role_name

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "codedeploy.amazonaws.com"
      }
    }]
  })
}

# AWS 기본 제공 정책 - CodeDeploy 실행용
resource "aws_iam_role_policy_attachment" "codedeploy_role_policy" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# AWS 기본 제공 정책 - CodeDeploy 콘솔 제어용 (선택사항)
resource "aws_iam_role_policy_attachment" "codedeploy_codedeploy_full_policy" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployFullAccess"
}

# ✅ 사용자 정의 정책 - Blue/Green 배포를 위한 추가 권한
resource "aws_iam_policy" "codedeploy_bluegreen_policy" {
  name = var.codedeploy_bluegreen_policy_name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:Describe*",
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyTargetGroup",
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:Describe*",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:PutLifecycleHook",
          "autoscaling:DeleteLifecycleHook",
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:RecordLifecycleActionHeartbeat",
          "autoscaling:*", # ✅ 모든 Auto Scaling 권한 부여
          "iam:PassRole",   # ✅ Green ASG에 EC2 역할 적용 시 필요
          "ec2:CreateTags",
          "ec2:RunInstances"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy_bluegreen_policy_attach" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = aws_iam_policy.codedeploy_bluegreen_policy.arn
}


########################################
# EC2 인스턴스 IAM 역할 생성 및 정책 첨부
########################################

resource "aws_iam_role" "ec2_role" {
  name = var.ec2_role_name

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "ssm_parameter_read" {
  name        = var.ssm_parameter_read_name
  description = "Allow EC2 instance to read SSM parameters for /spring path"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter",
          "ssm:GetParametersByPath"
        ],
        Resource = "arn:aws:ssm:ap-northeast-2:266735804784:parameter/spring/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_s3_full_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_codedeploy_full_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployFullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr_full_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_parameter_read_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ssm_parameter_read.arn
}

########################################
# EC2 인스턴스 프로파일 생성
########################################

resource "aws_iam_instance_profile" "ec2_profile" {
  name = var.ec2_instance_profile_name
  role = aws_iam_role.ec2_role.name
}