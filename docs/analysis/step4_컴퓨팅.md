# Step 4. 컴퓨팅(EC2/ASG/ALB) & ECR 구조 분석

작성일: 2026-07-04
대상: `Terraform_Project/modules/{ec2,asg,alb,ecr}/*`, `environments/{dev,prod}/*.tfvars`

---

## 1. EC2 구성 (`modules/ec2` — WAS 앱 서버용 Launch Template)

`ec2` 모듈은 `aws_instance`를 직접 생성하지 않고 **`aws_launch_template`만 생성**하여 `asg` 모듈에 넘겨주는 구조입니다(실제 인스턴스는 ASG가 기동).

### 1-1. 인스턴스 타입 및 AMI 설정

| 항목 | dev | prod |
|---|---|---|
| AMI | `ami-05a7f3469a7653972` (Ubuntu 22) | 동일 |
| 인스턴스 타입 | `t3.medium` | 동일 |
| Launch Template 이름 접두어 | `was-launch-template-` | 동일 |

- dev/prod가 동일한 AMI·인스턴스 타입을 사용 — 환경 간 스펙 차등 없이 값만 복제된 상태입니다(비용/성능 요구사항에 따라 향후 조정 여지가 있어 보입니다).

### 1-2. 키페어 / IAM 인스턴스 프로파일 설정

- 키페어: `was_key_name = "KoCo_testServer_key"` (dev/prod 동일 키 사용 — SSH는 직접 사용하지 않고 CodeDeploy 배포만 쓴다면 문제 없지만, 동일 키를 운영/개발 환경에 공유하는 것은 키 유출 시 영향 범위가 넓어지는 리스크가 있습니다.)
- IAM 인스턴스 프로파일: `iam_instance_profile_name`(→ `module.iam.ec2_instance_profile_name`)을 `iam_instance_profile` 블록에 연결 — S3/ECR/CodeDeploy/SSM 관련 권한을 위임받는 구조(step2 분석 참고).
- 메타데이터 옵션: `http_tokens = "required"`로 **IMDSv2 강제** — SSRF를 통한 메타데이터 탈취를 막는 보안 모범 사례가 적용되어 있습니다.

### 1-3. 배치 서브넷

- Launch Template 자체에는 서브넷 지정이 없고, `asg` 모듈의 `vpc_zone_identifier = module.network.private_app_subnet_ids`를 통해 **프라이빗 앱 서브넷(2a/2c)**에 배치됩니다 — 인터넷에서 직접 도달할 수 없는 위치입니다(step3 네트워크 분석과 일치).

### 1-4. 사용자 데이터(User Data) 스크립트

`was_user_data`(dev/prod 공통 내용)는 부팅 시 다음을 순서대로 수행합니다.

1. `apt-get update/upgrade` — OS 패키지 최신화
2. AWS CLI v2 설치
3. Docker CE + Docker Compose(1.29.2, 구버전) 설치, `docker` 그룹에 `ubuntu` 사용자 추가
4. **CodeDeploy 에이전트 설치**(`aws-codedeploy-ap-northeast-2` S3 버킷에서 설치 스크립트 다운로드) 및 서비스 활성화

- 이 스크립트 자체가 **CodeDeploy 배포를 받을 수 있는 최소 런타임(Docker + CodeDeploy Agent)을 준비하는 역할**이며, 실제 애플리케이션 배포는 user_data가 아니라 CodeDeploy를 통해 이뤄지는 구조임을 보여줍니다(→ step5에서 다룰 CodeDeploy 분석과 직결).
- Docker Compose 1.29.2는 2021년에 릴리스된 v1 계열의 구버전으로, 현재는 Docker Compose v2(플러그인 방식, `docker compose`)로 전환하는 것이 일반적입니다.

---

## 2. Auto Scaling Group 구성 (`modules/asg`)

### 2-1. Launch Template 연동

```hcl
launch_template {
  id      = var.launch_template_id       # module.ec2.launch_template_id
  version = var.launch_template_version  # "$Latest"
}
```

- `version = "$Latest"`로 고정 — Launch Template이 갱신(새 버전 생성)되면 ASG가 **명시적 재배포 없이도 다음 스케일 이벤트 때 자동으로 최신 버전을 사용**하게 됩니다. 다만 이는 의도치 않은 버전 드리프트로 이어질 수도 있어, 특정 배포 파이프라인(CodeDeploy)과 별개로 인스턴스 스펙이 바뀔 수 있다는 점은 유의가 필요합니다.

### 2-2. 최소/최대/희망 인스턴스 수

| 환경 | desired_capacity | min_size | max_size |
|---|---|---|---|
| dev | 1 | 1 | 1 |
| prod | 1 | 1 | 1 |

- **dev·prod 모두 인스턴스 1대 고정**입니다. `min=max=desired=1`이므로 스케일 아웃/인이 일어날 여지가 없는 구성입니다.

### 2-3. 스케일링 정책

- `aws_autoscaling_policy`(CPU 기반 Target Tracking, 스케줄 기반 등) 리소스가 **모듈 어디에도 정의되어 있지 않음** — 스케일링 정책 자체가 없습니다.
- 결과적으로 이 ASG는 "오토스케일링 그룹"이라는 이름과 달리 실질적으로는 **고정 인스턴스 수 1대를 유지·자동 복구(self-healing)하는 용도**로만 사용되고 있습니다(인스턴스 장애 시 ASG가 자동으로 새 인스턴스를 기동해주는 이점만 활용).
- `create_before_destroy = true` lifecycle 설정으로, ASG 자체를 교체해야 하는 경우 기존 것을 먼저 지우지 않고 새로 만든 뒤 교체하도록 되어 있어 무중단성을 일부 보강합니다.

### 2-4. 헬스 체크 설정

| 환경 | health_check_type | health_check_grace_period |
|---|---|---|
| dev | `"EC2"` | 300초 |
| prod | `"EC2"` | 300초 |

- `variables.tf`의 기본값은 `"ELB"`이지만 실제 tfvars에서 `"EC2"`로 오버라이드되어 있습니다.
- ⚠️ **관찰**: ALB Blue/Green 타겟그룹(`target_group_arns`)에 연결되어 있음에도 헬스체크 타입이 `EC2`(인스턴스 상태만 확인)로 설정되어 있어, **애플리케이션 레벨(HTTP `/actuator/health`) 헬스 체크 실패를 ASG가 감지하지 못합니다.** 인스턴스는 살아있지만 앱 프로세스가 죽은 경우 ASG는 이를 비정상으로 인식하지 않고 교체하지 않습니다 — `health_check_type = "ELB"`로 바꾸면 ALB의 타겟그룹 헬스체크 결과와 연동되어 더 정교한 자동 복구가 가능합니다.

---

## 3. ALB (Application Load Balancer) 구성 (`modules/alb`)

### 3-1. 리스너 설정

| 리스너 | 포트/프로토콜 | 동작 |
|---|---|---|
| HTTP | 80 | `redirect` → HTTPS(443), `HTTP_301` |
| HTTPS | 443 | `forward` → `target_group.BlueGreen` (기본 액션) |

- HTTP(80)로 들어온 요청은 전부 HTTPS로 301 리다이렉트 — 평문 트래픽을 허용하지 않는 구성입니다.
- HTTPS 리스너의 `ssl_policy = "ELBSecurityPolicy-2016-08"`은 다소 오래된 정책(2016년 버전)으로, 최신 TLS 보안 정책(`ELBSecurityPolicy-TLS13-1-2-2021-06` 등)으로 갱신하면 더 강한 암호 스위트를 강제할 수 있습니다.

### 3-2. 타겟 그룹 구성

- `aws_lb_target_group.BlueGreen` 1개만 정의(이름 `tg-BlueGreen`, 포트 8080/HTTP, `target_type = "instance"`).
- **Blue/Green이라는 이름과 달리 실제로는 타겟그룹이 1개뿐**입니다. CodeDeploy의 Blue/Green 배포 방식은 배포 시점에 **CodeDeploy가 두 번째(Green) 타겟그룹을 임시로 만들고 트래픽을 전환한 뒤 정리**하는 방식이므로, Terraform이 관리하는 것은 최초 1개(Blue)뿐이고 배포 중 생성되는 임시 Green 타겟그룹은 Terraform state 밖에서 CodeDeploy가 직접 관리하는 구조로 추정됩니다(→ step5에서 codedeploy 모듈 확인 시 교차 검증 필요).

### 3-3. 헬스 체크 경로 및 설정

```hcl
health_check {
  path                = "/actuator/health"
  interval            = 30
  timeout             = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
  matcher             = "200"
}
```

- `/actuator/health`는 Spring Boot Actuator의 기본 헬스체크 엔드포인트 — 애플리케이션이 **Spring Boot(Java) 기반**임을 시사합니다.
- 30초 간격, 2회 연속 성공/실패로 상태 전환 — 표준적인 값입니다.

### 3-4. SSL/TLS 인증서 설정

- `alb_dns_acm_certificate_arn`을 통해 환경별 ACM 인증서를 주입:
  - dev: `arn:aws:acm:ap-northeast-2:...c29976ee-...` 
  - prod: `arn:aws:acm:ap-northeast-2:...007027bc-...` (주석: `*.ktbkoco.com` 와일드카드)
- ALB용 인증서는 **`ap-northeast-2`(서울) 리전**에서 발급(리전 로드밸런서용), 반면 CDN(CloudFront)용 인증서는 이전 분석(step2)에서 확인된 대로 `us-east-1` 리전에서 별도 발급 — CloudFront는 반드시 `us-east-1` ACM 인증서만 사용 가능하다는 AWS 제약을 정확히 반영한 구성입니다.

### 3-5. ALB → ASG 연결 구조

```
Route53 (api.<domain>, www.api.<domain>)
        │  A record (alias → ALB dns_name)
        ▼
   ALB (internet-facing, public subnet)
   ├─ Listener :80  → redirect → :443
   └─ Listener :443 (ACM cert) → forward
                │
                ▼
     Target Group "tg-BlueGreen" (port 8080, HTTP)
       health_check: GET /actuator/health
                │
                ▼
        ASG (target_group_arns 연결)
                │
                ▼
   EC2 인스턴스(private_app subnet, port 8080 수신)
```

- ALB는 Route53 alias 레코드(`api.<domain>`, `www.api.<domain>`)로 도메인과 연결되고, 타겟그룹을 통해 ASG의 인스턴스(8080 포트)로 트래픽을 전달합니다.
- `security_groups` 모듈 분석(step3)과 결합하면: `0.0.0.0/0 → alb_sg(443) → app_sg(8080, SG 참조) → EC2`의 흐름이 완성됩니다.

---

## 4. ECR (Elastic Container Registry) 구성 (`modules/ecr`)

### 4-1. 레포지토리 설정

| 항목 | dev | prod |
|---|---|---|
| 레포지토리 이름 | `app-repo` | `app-repo` (동일 이름) |
| 태그 | `Name=dev-App-Repo, Environment=dev` | `Name=prod-App-Repo, Environment=prod` |

⚠️ **주의**: dev와 prod의 ECR `repository_name`이 **동일하게 `"app-repo"`**로 설정되어 있습니다. ECR 리포지토리 이름은 **AWS 계정+리전 내에서 전역적으로 유일**해야 하므로, 두 환경이 같은 AWS 계정의 같은 리전(`ap-northeast-2`)을 쓴다면 두 환경을 동시에 apply할 경우 이름 충돌이 발생하거나(둘 중 하나가 이미 존재하는 리소스를 가리키게 되는) `terraform import` 상태 충돌 문제가 생길 수 있습니다. 실제로는 두 환경이 **동일한 ECR 리포지토리 하나를 공유**하고 있을 가능성이 높습니다(각 환경의 state에 동일 리소스가 이중으로 관리되려고 시도하는 구조적 이슈).

### 4-2. 이미지 태그 정책

- `image_tag_mutability = "MUTABLE"` — 동일 태그(`latest` 등)로 이미지를 덮어쓰기 가능. 배포 파이프라인에서 `latest` 태그를 재사용하는 방식이라면 편리하지만, **롤백 시 특정 커밋의 이미지를 확정적으로 재현하기 어려울 수 있어** `IMMUTABLE`로 전환하고 커밋 SHA 등을 태그로 사용하는 것이 배포 추적성 측면에서 더 안전합니다.

### 4-3. 접근 권한 설정

- ECR 모듈 자체에는 리포지토리 정책(`aws_ecr_repository_policy`)이 없고, 접근 제어는 `iam` 모듈에서 EC2/CodeDeploy 역할에 ECR 관련 정책을 부여하는 방식으로 이뤄집니다(step2 분석: `iam` 모듈이 ECR 접근 정책 포함).
- `scan_on_push = true` — 이미지 푸시 시 자동 취약점 스캔 활성화(보안 모범 사례 적용).

---

## 5. 전체 컴퓨팅 트래픽 흐름

### 5-1. 클라이언트 → ALB → ASG(EC2) 흐름

```
[클라이언트]
    │  HTTPS
    ▼
[Route53] api.<domain> / www.api.<domain>
    │  Alias
    ▼
[ALB] (퍼블릭 서브넷, 2-AZ)
    │  :443 → tg-BlueGreen (health check: /actuator/health)
    ▼
[ASG] (desired=min=max=1, 프라이빗 앱 서브넷 2-AZ 대상)
    │  Launch Template(app_lt) 기반 기동
    ▼
[EC2 인스턴스] (t3.medium, Docker + CodeDeploy Agent)
    │  Docker 컨테이너로 앱 실행 (Spring Boot, :8080)
    ▼
[database-ec2] (MySQL, 프라이빗 DB 서브넷)
```

- 배포 대상 이미지는 `ecr`(app-repo)에 저장되고, CodeDeploy가 EC2에 배포 지시를 내리면 인스턴스의 CodeDeploy Agent가 배포를 수행 → Docker로 컨테이너 실행(구체적 배포 스크립트는 step5에서 `codedeploy`/`appspec.yml` 분석 시 확인 예정).

### 5-2. 고가용성 설계 여부

| 계층 | HA 수준 |
|---|---|
| 네트워크(서브넷) | 2-AZ(2a/2c) 이중화 (step3 참고) |
| ALB | 2개 퍼블릭 서브넷에 걸쳐 배치되는 관리형 서비스 — AZ 장애에 자동 대응 |
| ASG/EC2 | **`min=max=desired=1`로 사실상 단일 인스턴스** — `vpc_zone_identifier`에 2-AZ 서브넷을 지정했지만 인스턴스가 1대뿐이라 실제로는 특정 AZ 한 곳에서만 실행되며, 해당 AZ 장애 시 서비스 중단이 발생합니다. ASG의 자동 복구(비정상 인스턴스 교체)만 이뤄질 뿐, 진정한 다중 AZ 부하 분산은 이루어지지 않습니다.
| DB(EC2) | 이중화 없음(RDS Multi-AZ 아닌 단일 EC2 MySQL) — step3에서 이미 지적된 사항과 동일 |
| 스케일링 정책 | 없음 — 트래픽 증가에 따른 자동 확장 불가 |

- **종합 평가**: 네트워크 계층은 2-AZ HA를 준비해 두었지만, 실제 컴퓨팅 계층(ASG 인스턴스 수 1, 스케일링 정책 없음, DB 단일 EC2)은 그 잠재력을 활용하지 못하고 있어 **"HA를 위한 인프라는 갖췄으나 실제 가동은 단일 인스턴스"**인 상태입니다. 이는 개발/초기 운영 단계에서 비용을 최소화하기 위한 의도적 선택으로 보이며, 트래픽 증가 시 `desired_capacity`/`max_size` 상향과 `health_check_type = "ELB"` 전환, 스케일링 정책 추가가 필요합니다.

---

## 요약

- **EC2**: Launch Template 방식(t3.medium, Ubuntu 22 AMI 동일), IMDSv2 강제, user_data로 Docker+CodeDeploy Agent 설치까지만 수행(앱 배포는 CodeDeploy가 담당) — 프라이빗 앱 서브넷 배치.
- **ASG**: `min=max=desired=1` 고정, 스케일링 정책 없음(사실상 self-healing 전용), 헬스체크가 `EC2` 타입이라 ALB 타겟그룹 상태를 반영하지 못함(개선 포인트).
- **ALB**: 80→443 강제 리다이렉트, 타겟그룹 1개(`tg-BlueGreen`)에 `/actuator/health` 헬스체크(Spring Boot 추정), ACM 인증서는 서울 리전(alb)/버지니아 리전(cdn)으로 올바르게 분리.
- **ECR**: dev/prod가 동일한 `app-repo` 이름을 사용 — 실질적으로 리포지토리를 공유하고 있을 가능성이 높아 확인 필요, `MUTABLE` 태그 정책은 롤백 추적성 관점에서 재검토 여지.
- **HA**: 네트워크는 2-AZ로 설계되었으나 ASG 인스턴스 수(1), DB(단일 EC2), 스케일링 정책 부재로 인해 실질적인 다중 AZ 고가용성은 아직 구현되지 않은 상태.
