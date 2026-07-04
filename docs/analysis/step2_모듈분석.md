# Step 2. 루트 모듈 & 모듈 인터페이스 분석

작성일: 2026-07-04
대상: `Terraform_Project/environments/{dev,prod,dev_kubeadm}` (루트 모듈), `Terraform_Project/modules/*` (인터페이스)

---

## 1. 루트 모듈 구성

### 1-1. 호출하는 모듈 목록

| 환경 | 호출 모듈 (13개 중) |
|---|---|
| `dev` | network, s3_static_site, cdn, ecr, iam, security_groups, codedeploy, ec2, asg, alb, openvpn, monitoring-ec2, database-ec2 (**13개 전부**) |
| `prod` | dev와 동일, 13개 전부 |
| `dev_kubeadm` | network, s3_static_site, cdn, ecr, iam, security_groups, alb, openvpn, database-ec2 (**9개**, `codedeploy`/`ec2`/`asg`/`monitoring-ec2` 제외 — 앱 서버를 쿠버네티스(kubeadm)로 대체하는 실험 구성으로 추정) |

`dev`/`prod`는 모듈 구성과 `main.tf` 구조가 완전히 동일하며, `variables.tf`에 선언된 변수 이름도 동일합니다. 차이는 오직 `dev.tfvars` / `prod.tfvars`의 값(리소스 이름 접두어, CIDR, AMI, 인스턴스 타입 등)뿐입니다.

### 1-2. 모듈 간 데이터 전달 방식 (output → input 연결)

루트 모듈(`main.tf`)에서 `module.<name>.<output>` 형태로 다른 모듈의 output을 그대로 다음 모듈의 input으로 전달하는 **명시적 output→input 참조 방식**을 사용합니다. 예:

```hcl
module "security_groups" {
  vpc_id = module.network.vpc_id            # network output → security_groups input
}

module "alb" {
  subnet_ids         = module.network.public_subnet_ids
  security_group_ids = [module.security_groups.alb_sg_id]
  vpc_id             = module.network.vpc_id
}

module "asg" {
  launch_template_id             = module.ec2.launch_template_id
  vpc_zone_identifier             = module.network.private_app_subnet_ids
  alb_target_group_bluegreen_arn  = module.alb.target_group_BlueGreen_arn
}

module "codedeploy" {
  service_role_arn       = module.iam.codedeploy_role_arn
  alb_target_group_name  = module.alb.target_group_BlueGreen_name
  alb_listener_https_arn = module.alb.alb_listener_https_arn
  autoscaling_groups     = [module.asg.asg_name]
}
```

암묵적 의존은 `depends_on`으로 한 번 더 명시(주로 network/iam/alb/asg 등 선행 모듈에 대해)하고 있어, 데이터 흐름(참조)과 실행 순서(depends_on)가 이중으로 관리되고 있습니다.

> **주의할 인터페이스 불일치**: `cdn` 모듈은 `alb_dns_name`, `domain_name`, `acm_certificate_arn`, `waf_web_acl_id`를 모두 루트 변수(`var.*`)로 직접 받고 있어, 실제로는 `module.alb.alb_dns_name` output을 사용하지 않습니다. ALB가 먼저 생성된 후 실제 DNS 이름을 CDN에 자동 연결하려면 `var.alb_dns_name` → `module.alb.alb_dns_name`으로 바꾸는 것이 구조적으로 더 일관됩니다.

---

## 2. 모듈별 인터페이스 정리

| 모듈 | 주요 Input 변수 | 주요 Output 값 |
|---|---|---|
| `network` | `env`, `vpc_cidr`, `vpc_tag_name`, `igw_tag_name`, `public_subnets`(list(object{cidr,az})), `private_app_subnets`, `private_db_subnets`, `eip_nat_tag_name`, `nat_gateway_tag_name`, `public_rt_tag_name` | `vpc_id`, `public_subnet_ids`, `private_app_subnet_ids`, `private_db_subnet_ids`, `nat_gateway_ids` |
| `security_groups` | `vpc_id` | `openvpn_sg_id`, `alb_sg_id`, `app_sg_id`, `db_sg_id` |
| `iam` | `codedeploy_role_name`, `ec2_role_name`, `ec2_instance_profile_name`, `codedeploy_bluegreen_policy_name`, `ssm_parameter_read_name` | `codedeploy_role_arn`, `ec2_role_arn`, `ec2_instance_profile_name` |
| `ec2` | `launch_template_name_prefix`, `launch_template_image_id`, `was_instance_type`, `was_key_name`, `was_user_data`, `iam_instance_profile_name`, `security_group_ids` | `launch_template_id` |
| `asg` | `asg_name`, `vpc_zone_identifier`, `launch_template_id`, `launch_template_version`, `desired_capacity`, `min_size`, `max_size`, `health_check_type`, `health_check_grace_period`, `instance_tag_name`, `alb_target_group_bluegreen_arn` | `asg_name`, `asg_arn` |
| `alb` | `domain_name`, `env`, `alb_name`, `subnet_ids`, `security_group_ids`, `vpc_id`, `target_group_name`, `alb_dns_acm_certificate_arn` | `alb_arn`, `alb_dns_name`, `target_group_BlueGreen_arn`, `target_group_BlueGreen_name`, `alb_listener_https_arn` |
| `codedeploy` | `app_name`, `deployment_group_name`, `service_role_arn`, `autoscaling_groups`, `alb_listener_https_arn`, `alb_target_group_name` | `codedeploy_app_name`, `codedeploy_deployment_group_name` |
| `cdn` | `s3_bucket_name`, `default_root_object`, `alb_dns_name`, `domain_name`, `acm_certificate_arn`, `waf_web_acl_id` | `cloudfront_oai_arn` |
| `s3_static_site` | `env`, `bucket_name`, `cloudfront_oai_arn` | `dns_name`, `s3_bucket_name` |
| `ecr` | `repository_name`, `image_tag_mutability`, `scan_on_push`, `tags` | `repository_url`, `repository_arn` |
| `openvpn` | `openvpn_ami`, `openvpn_instance_type`, `subnet_id`, `vpc_security_group_ids`, `associate_public_ip_address`, `openvpn_key_name`, `openvpn_tags` | *(outputs.tf 비어있음 — output 없음)* |
| `monitoring-ec2` | `vpc_id`, `private_subnet_id`, `monitoring_server_ami`, `monitoring_server_instance_type`, `monitoring_server_private_ip`, `monitoring_server_key_name`, `monitoring_server_tags`, `monitoring_ec2_sd_role_name`, `monitoring_ec2_sd_policy_name`, `monitoring_instance_profile_name` | *(outputs.tf 비어있음 — output 없음)* |
| `database-ec2` | `security_group_db_sg_id`, `subnet_private_id`, `db_server_ami`, `db_server_instance_type`, `db_server_private_ip`, `db_server_key_name`, `db_server_user_data`, `db_server_tags`, `ec2_s3_access_name`, `s3_access_policy_name`, `ec2_profile_name` | *(outputs.tf 비어있음 — output 없음)* |

> `openvpn`, `monitoring-ec2`, `database-ec2` 3개 모듈은 다른 모듈에서 참조할 output이 없어 리프(leaf) 모듈로만 동작합니다.

---

## 3. 모듈 간 의존성 관계

### 3-1. output 참조 매트릭스

| 참조하는 모듈 | 참조되는 모듈 (output) |
|---|---|
| `security_groups` | `network` (`vpc_id`) |
| `alb` | `network` (`public_subnet_ids`, `vpc_id`), `security_groups` (`alb_sg_id`) |
| `ec2` | `iam` (`ec2_instance_profile_name`), `security_groups` (`app_sg_id`) |
| `asg` | `ec2` (`launch_template_id`), `network` (`private_app_subnet_ids`), `alb` (`target_group_BlueGreen_arn`) |
| `codedeploy` | `iam` (`codedeploy_role_arn`), `alb` (`target_group_BlueGreen_name`, `alb_listener_https_arn`), `asg` (`asg_name`) |
| `openvpn` | `network` (`public_subnet_ids[0]`), `security_groups` (`openvpn_sg_id`) |
| `monitoring-ec2` | `network` (`vpc_id`, `private_app_subnet_ids[0]`) |
| `database-ec2` | `network` (`private_db_subnet_ids[0]`), `security_groups` (`db_sg_id`) |
| `s3_static_site` | `cdn` (`cloudfront_oai_arn`) |
| `network`, `iam`, `ecr`, `cdn`, `security_groups` | *(다른 모듈에 의존하지 않는 최상위 모듈)* |

*(`dev_kubeadm`은 `codedeploy`/`ec2`/`asg`가 없어 위 표에서 해당 행이 빠지고, 나머지 참조 관계는 동일합니다.)*

### 3-2. 의존성 흐름도 (텍스트)

```
network ──┬─→ security_groups ──┬─→ alb ──┬─→ asg ──→ codedeploy
          │                     │         │            ↑
          │                     │         └────────────┘ (iam.codedeploy_role_arn)
          │                     │
          │                     ├─→ ec2 ──→ asg
          │                     │    ↑
          │                     │  iam (ec2_instance_profile_name)
          │                     │
          │                     ├─→ openvpn
          │                     └─→ database-ec2
          │
          ├─→ monitoring-ec2 (vpc_id, private_app_subnet_ids)
          ├─→ alb (public_subnet_ids, vpc_id)
          ├─→ asg (private_app_subnet_ids)
          ├─→ openvpn (public_subnet_ids[0])
          └─→ database-ec2 (private_db_subnet_ids[0])

iam ──┬─→ ec2 (ec2_instance_profile_name)
      └─→ codedeploy (codedeploy_role_arn)

cdn ──→ s3_static_site (cloudfront_oai_arn)

ecr        (독립 — 어떤 모듈도 output을 참조하지 않음)
```

**해석**: `network`가 사실상 모든 컴퓨트/보안 모듈의 최상위 의존 대상이며, `security_groups`가 두 번째 허브 역할을 합니다. 앱 계층은 `iam → ec2 → asg → alb → codedeploy` 순서로 이어지는 선형 체인이고, `cdn → s3_static_site`는 별도의 독립 체인입니다. `ecr`, `openvpn`, `monitoring-ec2`, `database-ec2`는 다른 모듈의 output을 소비하지 않는(또는 leaf인) 상대적으로 독립적인 모듈입니다.

---

## 4. Terraform 백엔드 설정

- **State 저장 방식**: S3 백엔드 사용 (`backend "s3"` 블록, `environments/{dev,prod,dev_kubeadm}/providers.tf`)
  - 버킷: `koco-terraformstate` (모든 환경 공용, `backend/main.tf`에서 사전 생성)
  - Key: `dev/terraform.tfstate`, `prod/terraform.tfstate` (동일한 버킷 내 경로(prefix)로 환경 구분) — 단, ⚠️ **정정**: `environments/dev_kubeadm/providers.tf`도 `key = "dev/terraform.tfstate"`로 설정되어 있어 **dev와 완전히 동일한 key를 사용**합니다. dev_kubeadm은 별도 key로 분리되지 않고 실제 dev 환경과 동일한 원격 state를 공유하며, dev_kubeadm을 apply하면 dev의 state를 그대로 읽고 덮어쓰게 되는 state 레벨 충돌 위험이 있습니다. (`prod`만 `prod/terraform.tfstate`로 정상 분리됨)
  - `encrypt = true` — state 파일 저장 시 암호화
  - 리전: `ap-northeast-2`
- **State 잠금(Lock) 방식**: DynamoDB 테이블 `koco-terraformstate` (`dynamodb_table` 옵션, PAY_PER_REQUEST 과금, 해시키 `LockID`) — 동시 `apply` 충돌 방지
- **부트스트랩 특성**: `backend/main.tf`는 S3 버킷 자체를 만드는 리소스이므로 이 state는 로컬(`backend/terraform.tfstate`)로 관리되며, 반드시 다른 환경들보다 먼저 apply되어야 합니다.
- **버킷 보안**: 버전관리(`aws_s3_bucket_versioning`) 활성화, 기본 SSE(AES256) 암호화, `aws_s3_bucket_public_access_block`으로 퍼블릭 접근 완전 차단.

---

## 5. Provider 설정

- **Provider**: `hashicorp/aws`
- **버전 고정 여부**: `~> 5.92.0` (환경 3곳 모두 동일, 패치 버전 범위만 허용하는 pessimistic constraint — **고정에 가까운 준-고정**). 단, `.terraform.lock.hcl` 실제 설치 버전은 `dev`/`dev_kubeadm`이 `5.92.0`, `prod`가 `5.92.0`으로 동일 (backend 쪽 lock 파일만 `5.99.1` 사용 확인됨 — 백엔드와 환경 간 provider 버전이 다소 어긋나 있음, 필요 시 통일 검토 권장)
- **Terraform 코어 버전**: `required_version = ">= 1.0.0"` — 하한만 지정, 상한 없음
- **AWS 리전**: `ap-northeast-2` (서울) — 3개 환경 모두 하드코딩되어 동일하게 고정
- **Provider 별칭/멀티 리전**: 없음 (단일 `provider "aws"` 블록만 존재)

---

## 6. 환경별 분리 전략

- **분리 방식**: Terraform **workspace는 사용하지 않으며**, `environments/dev`, `environments/prod`, `environments/dev_kubeadm` **디렉토리(루트 모듈)를 완전히 분리**하는 방식을 사용합니다. (`grep`으로 `terraform.workspace` 참조 없음을 확인)
- **State 분리**: 디렉토리별로 별도의 `.tf` 세트를 가지나, backend `key`는 `prod`만 별도(`prod/terraform.tfstate`)이고 `dev_kubeadm`은 `dev`와 동일한 key(`dev/terraform.tfstate`)를 그대로 사용하고 있어 **dev와 dev_kubeadm은 state가 분리되지 않고 공유됨** (같은 S3 버킷, dev_kubeadm-dev 간은 동일 key/prefix — state 레벨 충돌 위험)
- **변수 분리**: 환경 간 코드(`main.tf`/`variables.tf`/`providers.tf`)는 동일하게 유지하고, 값만 `dev.tfvars` / `prod.tfvars`로 분리하는 **"코드 공유 + 값만 분리"** 전략
  - 리소스 이름 규칙: `"${var.env}-${var.xxx_name}"` 형태로 접두어(`dev-`, `prod-`)를 붙여 리소스명 충돌 방지
- **staging 환경**: 존재하지 않음
- **dev_kubeadm의 위치**: 별도 워크스페이스가 아니라 완전히 새로운 디렉토리로, dev의 앱 서버 배포 방식(EC2 ASG + CodeDeploy)을 쿠버네티스(kubeadm)로 교체하기 위한 실험/과도기 환경으로 보입니다. 아직 git에 커밋되지 않은 untracked 상태입니다.
- **한계**: 디렉토리 복제 방식이라 `dev`/`prod`의 `main.tf`가 완전히 중복되어 있어(로직 변경 시 두 곳을 동시 수정해야 함), 모듈 자체의 재사용성은 높지만 루트 모듈 수준의 DRY(중복 제거)는 이루어지지 않은 구조입니다.
