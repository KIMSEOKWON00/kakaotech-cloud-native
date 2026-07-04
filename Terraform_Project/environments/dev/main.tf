module "network" {
  source               = "../../modules/network"
  env                  = var.env
  vpc_cidr             = var.vpc_cidr
  vpc_tag_name         = var.vpc_tag_name
  igw_tag_name         = var.igw_tag_name
  public_subnets       = var.public_subnets
  eip_nat_tag_name     = var.eip_nat_tag_name
  nat_gateway_tag_name = var.nat_gateway_tag_name
  public_rt_tag_name   = var.public_rt_tag_name 
  private_app_subnets  = var.private_app_subnets
  private_db_subnets   = var.private_db_subnets
}

module "s3_static_site" {
  source             = "../../modules/s3_static_site"
  env                = var.env
  bucket_name        = var.bucket_name

  cloudfront_oai_arn = module.cdn.cloudfront_oai_arn
} 

module "cdn" {
  source              = "../../modules/cdn"
  s3_bucket_name      = var.bucket_name
  default_root_object = var.default_root_object
  alb_dns_name        = var.alb_dns_name
  domain_name         = var.domain_name
  acm_certificate_arn = var.acm_certificate_arn
  waf_web_acl_id      = var.waf_web_acl_id
} 


module "ecr" {
  source               = "../../modules/ecr"
  repository_name      = "${var.env}-${var.repository_name}"
  image_tag_mutability = var.image_tag_mutability
  scan_on_push         = var.scan_on_push
  tags                 = var.tags
} 

module "iam" {
  source                     = "../../modules/iam"
  codedeploy_role_name       = "${var.env}-${var.codedeploy_role_name}"
  ec2_role_name              = "${var.env}-${var.ec2_role_name}"
  ec2_instance_profile_name  = "${var.env}-${var.ec2_instance_profile_name}"
  codedeploy_bluegreen_policy_name = "${var.env}-${var.codedeploy_bluegreen_policy_name}"
  ssm_parameter_read_name          = "${var.env}-${var.ssm_parameter_read_name}" 
}


module "security_groups" {
  source = "../../modules/security_groups"
  vpc_id = module.network.vpc_id
}

module "codedeploy" {
  source                 = "../../modules/codedeploy"
  app_name               = "${var.env}-${var.app_name}"
  deployment_group_name  = "${var.env}-${var.deployment_group_name}"

  alb_target_group_name  = module.alb.target_group_BlueGreen_name
  service_role_arn       = module.iam.codedeploy_role_arn
  alb_listener_https_arn = module.alb.alb_listener_https_arn
  autoscaling_groups     = [module.asg.asg_name]

  depends_on = [
    module.iam,      // iam 모듈이 완료된 후 실행
    module.alb,      // alb 모듈이 완료된 후 실행
    module.asg       // asg 모듈이 완료된 후 실행
  ]
}     

module "ec2" {
  source                      = "../../modules/ec2"
  launch_template_name_prefix = "${var.env}-${var.launch_template_name_prefix}"
  launch_template_image_id    = var.launch_template_image_id
  was_instance_type           = var.was_instance_type
  was_key_name                = var.was_key_name
  was_user_data               = var.was_user_data

  iam_instance_profile_name   = module.iam.ec2_instance_profile_name
  security_group_ids          = [module.security_groups.app_sg_id]
}


module "asg" {
  source                         = "../../modules/asg"
  asg_name                       = "${var.env}-${var.asg_name}"
  launch_template_version        = var.launch_template_version
  desired_capacity               = var.desired_capacity
  min_size                       = var.min_size
  max_size                       = var.max_size
  health_check_type              = var.health_check_type
  health_check_grace_period      = var.health_check_grace_period
  instance_tag_name              = "${var.env}-${var.instance_tag_name}"

  launch_template_id             = module.ec2.launch_template_id
  vpc_zone_identifier            = module.network.private_app_subnet_ids
  alb_target_group_bluegreen_arn = module.alb.target_group_BlueGreen_arn

  depends_on = [
    module.network,  // network 모듈이 완료된 후 실행
    module.alb,      // alb 모듈이 완료된 후 실행
    module.ec2       // ec2 모듈이 완료된 후 실행
  ]

}

module "alb" {
  source                      = "../../modules/alb"
  domain_name                 = var.domain_name
  env                         = var.env
  alb_name                    = "${var.env}-${var.alb_name}"
  target_group_name           = "${var.env}-${var.target_group_name}"
  alb_dns_acm_certificate_arn = var.alb_dns_acm_certificate_arn

  subnet_ids                  = module.network.public_subnet_ids        # 네트워크 모듈의 출력값 사용 가능
  security_group_ids          = [module.security_groups.alb_sg_id]      # ALB 전용 보안 그룹
  vpc_id                      = module.network.vpc_id                   # 네트워크 모듈의 VPC ID 사용

  depends_on = [
    module.network,  // network 모듈이 완료된 후 실행
    module.ec2       // ec2 모듈이 완료된 후 실행
  ]
}


module "openvpn" {
  source                      = "../../modules/openvpn"
  openvpn_ami                 = var.openvpn_ami
  openvpn_instance_type       = var.openvpn_instance_type
  associate_public_ip_address = var.associate_public_ip_address
  openvpn_key_name            = var.openvpn_key_name
  openvpn_tags                = var.openvpn_tags
  
  subnet_id                   = module.network.public_subnet_ids[0]
  vpc_security_group_ids      = [module.security_groups.openvpn_sg_id]

  depends_on = [
    module.network  // network 모듈이 완료된 후 실행
  ]
}

module "monitoring-ec2" {
  source                          = "../../modules/monitoring-ec2"
  monitoring_ec2_sd_role_name = "${var.env}-${var.monitoring_ec2_sd_role_name}"
  monitoring_ec2_sd_policy_name = "${var.env}-${var.monitoring_ec2_sd_policy_name}"
  monitoring_instance_profile_name = "${var.env}-${var.monitoring_instance_profile_name}"
  monitoring_server_ami           = var.monitoring_server_ami
  monitoring_server_instance_type = var.monitoring_server_instance_type
  monitoring_server_private_ip    = var.monitoring_server_private_ip
  monitoring_server_key_name      = var.monitoring_server_key_name
  monitoring_server_tags          = var.monitoring_server_tags

  vpc_id                          = module.network.vpc_id
  private_subnet_id               = module.network.private_app_subnet_ids[0]

  depends_on = [
    module.network  // network 모듈이 완료된 후 실행
  ]
}

module "database-ec2" {
  source                  = "../../modules/database-ec2"
  ec2_s3_access_name = "${var.env}-${var.ec2_s3_access_name}"
  s3_access_policy_name = "${var.env}-${var.s3_access_policy_name}"
  ec2_profile_name = "${var.env}-${var.ec2_profile_name}"
  db_server_ami           = var.db_server_ami
  db_server_instance_type = var.db_server_instance_type
  db_server_private_ip    = var.db_server_private_ip
  db_server_key_name      = var.db_server_key_name
  db_server_user_data     = var.db_server_user_data
  db_server_tags          = var.db_server_tags

  subnet_private_id       = module.network.private_db_subnet_ids[0]
  security_group_db_sg_id = module.security_groups.db_sg_id

  depends_on = [
    module.network  // network 모듈이 완료된 후 실행
  ]
}
 