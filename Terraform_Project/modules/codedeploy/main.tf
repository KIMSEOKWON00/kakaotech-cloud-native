##############################
# 6. CodeDeploy Application & Deployment Group
##############################
resource "aws_codedeploy_app" "was_app" {
  name             = var.app_name
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "was_dg" {
  app_name              = aws_codedeploy_app.was_app.name
  deployment_group_name = var.deployment_group_name
  service_role_arn      = var.service_role_arn

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }

    deployment_ready_option {
      action_on_timeout    = "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = 0
    }
  }


  autoscaling_groups = var.autoscaling_groups


  load_balancer_info {

     # ✅ 명시적으로 대상 그룹을 등록 !!반드시 필요!!
    target_group_info {
      name = var.alb_target_group_name
    }

    # 💡 핵심: CodeDeploy가 이 블록을 통해 대상 그룹과의 연결을 확실히 인식
    target_group_pair_info {
      target_group {
        name = var.alb_target_group_name
      }
      target_group {
        name = var.alb_target_group_name
      }
      
      prod_traffic_route {
        listener_arns = [var.alb_listener_https_arn]
      }
    }


  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  # 배포 방식: 필요 시 “CodeDeployDefault.HalfAtATime” 등의 다른 방식 선택 가능
  # 블루/그린 배포만 쓰신다면 deployment_config_name은 제거해도 무방합니다.
  # deployment_config_name = "CodeDeployDefault.AllAtOnce"

  
}
