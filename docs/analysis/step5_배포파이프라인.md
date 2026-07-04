# Step 5. CodeDeploy 배포 파이프라인 분석

작성일: 2026-07-04
대상: `Terraform_Project/modules/codedeploy/*`, `Terraform_Project/modules/iam/main.tf`(codedeploy 역할), 저장소 전체(CI/CD 관련 파일 탐색)

---

## 0. 사전 확인: CI/CD 관련 파일 존재 여부

분석에 앞서 저장소 전체(`21-iceT-cloud/`)를 대상으로 다음을 검색했습니다.

| 검색 대상 | 결과 |
|---|---|
| `.github/workflows/*.yml` (GitHub Actions) | **없음** — `.github/`에는 `PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/*`만 존재, 워크플로 파일 없음 |
| `appspec.yml` / `appspec.yaml` | **없음** — 저장소 어디에도 존재하지 않음 |
| `buildspec.yml` (CodeBuild) | **없음** |
| `Jenkinsfile`, `.gitlab-ci.yml` | **없음** |
| Terraform 내 `aws_codepipeline`, `aws_codebuild_project` 리소스 | **없음** (`grep -rniE "codepipeline|codebuild"` 결과 0건, `github` 문자열은 Docker Compose 다운로드 URL에서만 발견) |

> 이 저장소(Terraform_Project 포함)는 **인프라(IaC) 전용 저장소**이며, 애플리케이션 소스 코드·`appspec.yml`·CI 워크플로는 포함되어 있지 않습니다. 아래 분석은 Terraform으로 프로비저닝되는 **CodeDeploy 인프라 설정**을 기준으로 하며, 실제 빌드/배포 트리거(CI 파이프라인)는 이 저장소 밖(별도 애플리케이션 저장소 또는 수동 실행)에 존재할 것으로 추정됩니다.

---

## 1. CodeDeploy 구성 (`modules/codedeploy/main.tf`)

### 1-1. Application 및 Deployment Group 설정

```hcl
resource "aws_codedeploy_app" "was_app" {
  name             = var.app_name
  compute_platform = "Server"
}
```

- `compute_platform = "Server"` — **EC2/On-Premises 컴퓨팅 플랫폼**입니다(ECS나 Lambda 컴퓨팅 플랫폼이 아님). 애플리케이션 자체는 EC2 인스턴스 안에서 Docker 컨테이너로 실행되지만(step4 분석), 컨테이너 오케스트레이션(ECS) 배포가 아니라 **EC2 인스턴스에 CodeDeploy 에이전트가 설치되어 배포 지시를 받는 전통적인 "Server" 타입** 배포입니다.
- `service_role_arn = module.iam.codedeploy_role_arn` — `codedeploy.amazonaws.com`을 신뢰 주체로 하는 IAM 역할을 사용(아래 4절 참고).

### 1-2. 배포 대상 (EC2 태그 기반 / ASG 기반)

```hcl
autoscaling_groups = var.autoscaling_groups   # [module.asg.asg_name]
```

- 배포 대상은 **EC2 태그 기반이 아니라 ASG 기반**입니다. `ec2_tag_filter`/`ec2_tag_set` 블록은 전혀 사용되지 않고, `autoscaling_groups` 목록(현재 앱 ASG 1개)만 지정되어 있습니다.
- Blue/Green + `green_fleet_provisioning_option { action = "COPY_AUTO_SCALING_GROUP" }` 조합이므로, 배포 시점에 CodeDeploy가 **기존 ASG(Blue)의 설정을 그대로 복제한 임시 ASG(Green)를 자동 생성**합니다. step4에서 확인한 대로 원본 ASG가 `min=max=desired=1`이므로, 배포 중에는 일시적으로 Blue 1대 + Green 1대(총 2대)가 공존하는 구간이 생깁니다.

### 1-3. 배포 전략

**In-place vs Blue/Green**
```hcl
deployment_style {
  deployment_type   = "BLUE_GREEN"
  deployment_option = "WITH_TRAFFIC_CONTROL"
}
```
- **Blue/Green 배포**를 명시적으로 선택(`WITH_TRAFFIC_CONTROL` — ALB를 통한 트래픽 전환 제어 사용, In-place 방식이 아님).

**배포 설정(Deployment Config)**
```hcl
# deployment_config_name = "CodeDeployDefault.AllAtOnce"   # 주석 처리됨
```
- `deployment_config_name`이 **명시적으로 설정되어 있지 않고 주석 처리**되어 있어, AWS 기본값(Server 플랫폼 기본 `CodeDeployDefault.OneAtATime`)이 적용됩니다.
- 코드 내 주석("필요 시 HalfAtATime 등 다른 방식 선택 가능")으로 미루어, 작성자가 `AllAtOnce`/`HalfAtATime`/`OneAtATime` 옵션을 검토했으나 최종적으로 별도 지정하지 않고 기본값을 채택한 것으로 보입니다. 다만 ASG 인스턴스 수가 1대뿐이라 이 배치(batch) 크기 설정 자체는 (Green ASG의 인스턴스가 1대뿐이므로) 실질적인 영향이 크지 않습니다.

**Green 인스턴스 프로비저닝 및 Blue 정리**
```hcl
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
```
- `deployment_ready_option`이 `CONTINUE_DEPLOYMENT` + `wait_time_in_minutes = 0`으로 설정되어 있어, **트래픽 전환 전 수동 승인 절차가 없이 완전 자동으로 즉시 전환**됩니다(운영자가 개입할 기회 없음).
- `terminate_blue_instances_on_deployment_success`로 배포 성공 후 5분 대기 뒤 기존(Blue) 인스턴스를 자동 종료 — 즉시 삭제하지 않고 5분의 유예를 두어 트래픽 전환 직후 문제 발생 시 짧은 시간 내 롤백 여지를 남겨둔 것으로 보입니다.

**로드밸런서 연동**
```hcl
load_balancer_info {
  target_group_info {
    name = var.alb_target_group_name
  }
  target_group_pair_info {
    target_group { name = var.alb_target_group_name }
    target_group { name = var.alb_target_group_name }   # 두 블록 모두 동일한 이름
    prod_traffic_route {
      listener_arns = [var.alb_listener_https_arn]
    }
  }
}
```
- ⚠️ **관찰**: `target_group_pair_info` 내부의 두 `target_group` 블록이 **완전히 동일한 이름**(`var.alb_target_group_name`, 즉 `tg-BlueGreen` 하나)을 참조하고 있습니다. 코드 주석("✅ 반드시 필요 !!", "💡 핵심: ... 확실히 인식")으로 보아 작성자가 CodeDeploy 콘솔/API 요구사항을 맞추기 위해 시행착오를 거친 흔적으로 보이며, `target_group_info`와 `target_group_pair_info`를 중복으로 선언한 것도 다소 이례적인 구성입니다. 실제로는 `COPY_AUTO_SCALING_GROUP` 옵션 덕분에 CodeDeploy가 배포 시점에 두 번째(Green) 타겟 그룹을 **내부적으로 자동 생성**하므로, Terraform에는 원본 타겟 그룹 이름 하나만 참조로 넘기고 나머지는 CodeDeploy가 런타임에 처리하는 구조입니다.
- `prod_traffic_route.listener_arns`에 **HTTPS(443) 리스너 하나만** 지정 — 별도의 "테스트 리스너"(카나리/사전 검증용 트래픽 경로)는 구성되어 있지 않아, Green 환경 준비 완료 즉시 운영 트래픽 전체가 한 번에 전환되는 **All-at-once 방식의 트래픽 스위치**입니다.

### 1-4. 롤백 설정

```hcl
auto_rollback_configuration {
  enabled = true
  events  = ["DEPLOYMENT_FAILURE"]
}
```
- 자동 롤백이 활성화되어 있으나, 트리거 조건이 **`DEPLOYMENT_FAILURE`(배포 단계 자체의 실패) 하나뿐**입니다.
- CloudWatch 알람 기반 롤백(`DEPLOYMENT_STOP_ON_ALARM`)은 구성되어 있지 않습니다 — 즉, 배포는 "성공"했지만 배포 후 애플리케이션 에러율/지연시간이 급증하는 경우는 이 설정만으로는 자동 롤백되지 않습니다. step4에서 지적한 ASG의 `health_check_type = "EC2"`(ELB 상태 미반영) 이슈와 함께, **트래픽 전환 이후의 애플리케이션 레벨 이상 감지·자동 대응 체계가 약한 편**입니다.

---

## 2. 배포 흐름

### 2-1. 코드 → 빌드 → 배포 전체 흐름 (추정)

이 저장소에는 애플리케이션 코드, `appspec.yml`, 빌드 스크립트가 없으므로 **Terraform이 프로비저닝하는 인프라 요소로부터 역추적한 추정 흐름**입니다.

```
[애플리케이션 소스 저장소] (이 저장소 밖, 미확인)
        │  빌드 (Dockerfile → 이미지)
        ▼
[ECR: app-repo]  (docker push, scan_on_push=true로 자동 스캔)
        │
        │  (배포 리비전 패키징 — appspec.yml + 배포 스크립트 등, 위치 미확인)
        ▼
[CodeDeploy: was_app / was_dg]  ← aws deploy create-deployment (수동 또는 외부 파이프라인 호출)
        │  BLUE_GREEN + COPY_AUTO_SCALING_GROUP
        ▼
[임시 Green ASG] (Blue ASG 복제, 신규 EC2 기동)
        │  EC2 내 CodeDeploy Agent가 appspec.yml의 hooks 실행
        │  (예상: ECR 이미지 pull → docker-compose 등으로 컨테이너 기동)
        ▼
[ALB 리스너(HTTPS) 트래픽 전환] → Green으로 즉시 전체 전환 (wait_time_in_minutes=0)
        │
        ▼
[Blue 인스턴스 5분 대기 후 종료]
```

- EC2 인스턴스의 `iam_instance_profile`(`ec2_role`)에는 `AmazonS3FullAccess`, `AWSCodeDeployFullAccess`, `AmazonEC2ContainerRegistryFullAccess`, SSM 파라미터(`/spring/*`) 읽기 권한이 부여되어 있습니다(`modules/iam/main.tf`). 이는:
  - **S3FullAccess**: CodeDeploy가 배포 리비전(revision)을 S3 버킷에서 가져오는 전형적인 방식(GitHub 연동이 아닌 **S3 기반 리비전 저장 방식**일 가능성이 높음을 시사) — 또는 database-ec2가 사용하는 `koco-db-backup` 류 S3 접근과 공유되는 범용 권한일 수 있음.
  - **ECR FullAccess**: EC2 인스턴스가 배포 시 직접 `docker pull`로 ECR 이미지를 내려받는 구조임을 시사.
  - **SSM 파라미터(`/spring/*`) 읽기**: 애플리케이션(Spring Boot)이 기동 시 DB 접속 정보 등 설정값을 AWS Systems Manager Parameter Store에서 조회하는 방식으로 추정 — 시크릿을 코드/이미지에 하드코딩하지 않고 외부화한 설계입니다.

### 2-2. S3 또는 GitHub과의 연동 방식

- CodeDeploy `service_role_arn`에 연결된 정책은 AWS 관리형 `AWSCodeDeployRole`, `AWSCodeDeployFullAccess`, 그리고 커스텀 `codedeploy_bluegreen_policy`(EC2/ELB/ASG Describe 및 트래픽 전환 관련 권한)뿐이며, **GitHub 연동에 필요한 `codestar-connections` 리소스나 GitHub 웹훅 관련 설정은 어디에도 없습니다.**
- 반면 EC2 역할에 `AmazonS3FullAccess`가 부여된 점은 CodeDeploy의 전통적인 리비전 저장 방식인 **S3 버킷 기반 배포**를 뒷받침합니다(CodeDeploy는 GitHub 또는 S3 중 하나를 리비전 소스로 사용 가능하며, 이 구성에서는 S3 쪽 권한만 명시적으로 확인됨).
- 결론적으로 **GitHub 직접 연동의 흔적은 없으며, S3를 통한 배포 리비전 전달 방식일 가능성이 높습니다.** 다만 이 저장소만으로는 어느 S3 버킷을 리비전 저장소로 쓰는지, 리비전을 누가/어떻게 업로드하는지(수동 CLI vs 외부 CI)는 확인할 수 없습니다.

### 2-3. `appspec.yml` 구성

- **이 저장소에는 `appspec.yml`이 존재하지 않습니다.** `appspec.yml`은 배포 리비전(애플리케이션 코드/컨테이너 실행 스크립트와 함께 패키징되는 파일)에 포함되는 것이 일반적이므로, 인프라 전용인 이 Terraform 저장소가 아니라 **별도의 애플리케이션 소스 저장소**에 위치할 것으로 추정됩니다. 따라서 `hooks`(`BeforeInstall`, `ApplicationStart`, `ValidateService` 등)의 구체적 내용은 확인이 불가능합니다.

---

## 3. CI/CD 파이프라인 연동

### 3-1. GitHub Actions / CodePipeline 등 연동 여부

| 구성 요소 | 존재 여부 |
|---|---|
| GitHub Actions (`.github/workflows/*.yml`) | **없음** |
| AWS CodePipeline (`aws_codepipeline`) | **없음** |
| AWS CodeBuild (`aws_codebuild_project`) | **없음** |
| CodeStar Connections(GitHub 연동) | **없음** |

- 이 저장소 기준으로는 **완전 자동화된 CI/CD 파이프라인이 Terraform으로 프로비저닝되어 있지 않습니다.** CodeDeploy 애플리케이션/배포 그룹이라는 "배포 실행 인프라"만 존재하고, 그 앞단(빌드 트리거, 이미지 빌드, 배포 시작 명령)은 이 저장소 범위 밖에 있습니다.

### 3-2. 자동화된 배포 트리거 조건

- Terraform 코드상으로는 배포를 자동으로 트리거하는 조건(예: ECR 이미지 푸시 이벤트 → EventBridge → CodeDeploy 실행)이 **전혀 구성되어 있지 않습니다**(`aws_cloudwatch_event_rule`/`aws_scheduler_schedule` 등 트리거 리소스 없음).
- 따라서 배포는 다음 중 하나의 방식으로 이뤄질 것으로 추정됩니다.
  1. 운영자가 `aws deploy create-deployment` CLI 명령이나 AWS 콘솔에서 수동으로 배포를 시작
  2. 이 저장소에 포함되지 않은 **별도의 애플리케이션 저장소**에 GitHub Actions 등 CI 워크플로가 존재하여, 빌드 후 `aws deploy create-deployment`를 호출
- 어느 쪽이든 **현재 인프라 저장소만으로는 "무엇이 배포를 트리거하는지" 확정할 수 없다**는 점이 이번 분석의 핵심 한계입니다.

---

## 4. 배포 전략 선택 이유 분석

### 4-1. 왜 Blue/Green을 선택했는가 (코드에서 유추)

- `deployment_option = "WITH_TRAFFIC_CONTROL"` + ALB `target_group_pair_info` + `prod_traffic_route`의 조합은 **ALB 레벨에서 트래픽을 새 인스턴스 그룹으로 전환하는 전형적인 Blue/Green 무중단 배포 패턴**입니다. In-place 배포(기존 인스턴스에 순차적으로 새 코드를 배포)를 사용했다면 `deployment_type = "IN_PLACE"`와 `ec2_tag_filter`/`deployment_config_name`(OneAtATime 등)만으로 충분했을 텐데, 굳이 ASG를 통째로 복제하는 Blue/Green + `COPY_AUTO_SCALING_GROUP`을 택한 것은 **배포 중 이전 버전이 트래픽을 계속 처리하다가, 신규 버전이 완전히 준비된 뒤 한 번에 전환**하려는 의도가 명확합니다.
- `codedeploy_bluegreen_policy`(iam 모듈)에 `autoscaling:*` 전체 권한과 `iam:PassRole`, `ec2:RunInstances`까지 부여되어 있는 것도 Blue/Green의 "ASG 복제 → 새 인스턴스 기동 → 역할 재적용" 과정에 필요한 권한을 세심하게 준비한 흔적입니다.

### 4-2. 무중단 배포 고려 여부

- **설계 의도상으로는 명확히 무중단 배포를 목표**로 하고 있습니다: Blue 인스턴스가 살아있는 상태에서 Green을 준비 → 트래픽 전환 → Blue를 5분 뒤 종료하는 흐름 자체가 다운타임을 최소화하도록 짜여 있습니다.
- 다만 실제 효과 측면에서는 다음과 같은 **약한 고리(weak link)**가 있어, "무중단"이 완전히 보장되지는 않습니다.
  1. **ASG 인스턴스 수가 1대**(step4 분석) — Blue/Green 전환 자체는 무중단이지만, 배포 자체가 실패하거나 Green 인스턴스가 실제로는 비정상인데 CodeDeploy의 `ValidateService` 훅(내용 미확인)이 이를 못 잡아내면, 대체할 여분의 인스턴스가 없어 장애로 이어질 위험이 있습니다.
  2. **ASG `health_check_type = "EC2"`**(step4에서 지적) — ALB의 애플리케이션 레벨 헬스체크(`/actuator/health`) 결과가 ASG 자체의 인스턴스 상태 판정에는 반영되지 않으므로, Blue/Green 전환 판단이 CodeDeploy의 배포 훅 성공 여부에만 의존하게 됩니다.
  3. **CloudWatch 알람 기반 자동 롤백 미설정** — 트래픽 전환 후 에러율 급증 등은 자동으로 감지·롤백되지 않고, `DEPLOYMENT_FAILURE`(배포 절차 자체의 실패)만 롤백을 트리거합니다.
  4. **트래픽 전환 전 대기시간 0분**(`deployment_ready_option.wait_time_in_minutes = 0`) — 사람이 개입해 트래픽 전환 전 상태를 점검할 여지가 없어 완전 자동화되어 있지만, 반대로 이상 징후를 사전에 포착할 기회도 없습니다.

- **종합**: 무중단 배포를 위한 **인프라적 장치(Blue/Green, ASG 복제, 지연 종료)는 충실히 갖춰져 있으나**, 애플리케이션 상태를 배포 프로세스에 정교하게 반영하는 **검증·모니터링 계층(ELB 헬스체크 연동, 알람 기반 롤백)이 상대적으로 약해**, 실제 운영에서는 "인스턴스 교체는 무중단이지만 배포된 코드 자체의 이상은 빠르게 감지되지 않을 수 있는" 상태로 평가됩니다.

---

## 요약

- **CodeDeploy**: `compute_platform = "Server"`, Blue/Green(`WITH_TRAFFIC_CONTROL`) + ASG 기반(`COPY_AUTO_SCALING_GROUP`) 배포. EC2 태그 기반이 아님.
- **트래픽 전환**: HTTPS 리스너 단일 경로로 즉시 전체 전환(사전 대기 0분), 5분 뒤 Blue 인스턴스 자동 종료.
- **롤백**: `DEPLOYMENT_FAILURE` 시 자동 롤백만 구성, CloudWatch 알람 기반 롤백 없음.
- **CI/CD 파이프라인**: 이 저장소에는 **appspec.yml, GitHub Actions, CodePipeline/CodeBuild가 전혀 존재하지 않음** — CodeDeploy 인프라만 Terraform으로 준비되어 있고, 실제 빌드/배포 트리거는 저장소 밖(별도 앱 저장소 또는 수동 실행)에 있는 것으로 추정.
- **연동 방식**: GitHub 직접 연동 흔적 없음, EC2 역할의 S3FullAccess로 미루어 S3 기반 리비전 전달 가능성이 높음(확정 불가).
- **설계 의도**: 무중단 배포를 목표로 한 Blue/Green 인프라는 잘 갖춰졌으나, 애플리케이션 레벨 헬스체크·알람 기반 롤백 등 검증 계층이 상대적으로 약해 실제 무중단성은 제한적일 수 있음.
