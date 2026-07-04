# Step 1. Terraform IaC 프로젝트 구조 파악

작성일: 2026-07-04
대상 경로: `Terraform_Project/`

---

## 1. 전체 폴더 구조 트리 (depth 3~4)

```
Terraform_Project
├── backend                        # Terraform 원격 상태(state) 관리용 백엔드 리소스 정의
│   ├── .terraform.lock.hcl
│   ├── main.tf                    # S3 버킷(state) + DynamoDB 테이블(lock) 생성
│   └── terraform.tfstate          # backend 자체의 state 파일 (로컬)
│
├── environments                    # 환경별 루트 모듈 (실제 apply 단위)
│   ├── dev                         # 개발 환경
│   │   ├── .terraform.lock.hcl
│   │   ├── dev.tfvars              # dev 환경 변수 값
│   │   ├── main.tf                 # 전체 모듈 호출(조립) 파일
│   │   ├── providers.tf            # provider/backend(S3) 설정
│   │   └── variables.tf            # 변수 선언
│   ├── dev_kubeadm                 # kubeadm 기반 대체/실험 dev 환경 (신규, untracked)
│   │   ├── .terraform.lock.hcl
│   │   ├── dev.tfvars
│   │   ├── main.tf                 # dev와 유사하나 codedeploy/asg/monitoring 모듈 미포함
│   │   ├── providers.tf
│   │   └── variables.tf
│   └── prod                        # 운영 환경
│       ├── .terraform.lock.hcl
│       ├── main.tf                 # 전체 모듈 호출(조립) 파일 (dev와 동일 구조)
│       ├── prod.tfvars             # prod 환경 변수 값
│       ├── providers.tf            # provider/backend(S3) 설정
│       └── variables.tf            # 변수 선언
│
├── modules                         # 재사용 가능한 하위 모듈 (AWS 리소스 단위)
│   ├── alb                         # ALB, 리스너, 타겟그룹, Route53 레코드
│   ├── asg                         # Auto Scaling Group
│   ├── cdn                         # CloudFront, OAI, Route53 레코드
│   ├── codedeploy                  # CodeDeploy App/Deployment Group (Blue/Green)
│   ├── database-ec2                # DB용 EC2(MySQL) + 전용 IAM
│   ├── ec2                         # 앱(WAS) Launch Template
│   ├── ecr                         # ECR 리포지토리
│   ├── iam                         # 공용 IAM Role/Policy (codedeploy, ec2)
│   ├── monitoring-ec2              # 모니터링 서버 EC2 + 전용 IAM/SG
│   ├── network                     # VPC, Subnet, IGW, NAT, Route Table
│   ├── openvpn                     # OpenVPN 서버 EC2
│   ├── s3_static_site              # 프론트엔드 정적 호스팅 S3
│   └── security_groups             # 공용 보안그룹 (openvpn/alb/app/db)
│
└── Terraform-init                  # Terraform_Project와 분리된 별도 로컬 state 부가 리소스 저장소
    ├── s3-buckets
    │   ├── koco-alb-logs           # ALB 로그 버킷 (apply 실패, 빈 state)
    │   ├── koco-codedeploy-artifacts/{dev,prod}  # CodeDeploy 아티팩트 버킷
    │   └── koco-frontend-backup/{dev,prod}       # 프론트엔드 빌드 백업 버킷
    └── waf
        ├── dev_waf                 # CloudFront용 WAFv2 (dev)
        └── prod_waf                # CloudFront용 WAFv2 (prod)
```

각 모듈 폴더는 공통적으로 `main.tf`(리소스), `variables.tf`(입력 변수), `outputs.tf`(출력 값) 3종 파일로 구성됩니다. 단, `database-ec2`, `monitoring-ec2`는 `outputs.tf`가 없습니다.

---

## 2. 폴더/파일 역할 한 줄 설명

| 경로 | 역할 |
|---|---|
| `backend/main.tf` | Terraform state 저장용 S3 버킷 + 잠금용 DynamoDB 테이블 생성 (최초 1회 별도 apply) |
| `backend/terraform.tfstate` | backend 자체 리소스의 로컬 state 파일 |
| `environments/dev/` | 개발 환경 루트 모듈 — 전체 모듈을 조립해 dev 인프라를 구성 |
| `environments/dev_kubeadm/` | kubeadm 기반 구성을 실험 중인 대체 dev 환경 (codedeploy/asg/ec2/monitoring 모듈 제외, network+s3+cdn+ecr+iam+sg+alb+openvpn+database만 사용) |
| `environments/prod/` | 운영 환경 루트 모듈 — dev와 동일한 모듈 조합, 값만 다름 |
| `*/main.tf` (환경) | 모듈 호출 및 의존관계(`depends_on`) 정의 |
| `*/providers.tf` (환경) | AWS provider 버전, 리전, S3 backend(state key) 설정 |
| `*/variables.tf` (환경) | 루트 모듈에서 사용하는 변수 선언 |
| `*/*.tfvars` (환경) | 환경별 실제 변수 값 (리소스 이름, CIDR, AMI 등) |
| `modules/network/` | VPC/서브넷(퍼블릭·프라이빗 앱·프라이빗 DB)/IGW/NAT/라우팅 테이블 구성 |
| `modules/security_groups/` | openvpn, alb, app, db용 보안그룹 정의 |
| `modules/iam/` | codedeploy용/EC2용 공용 IAM Role, Policy, Instance Profile |
| `modules/ec2/` | WAS(앱 서버)용 EC2 Launch Template |
| `modules/asg/` | 앱 서버 Auto Scaling Group (Launch Template 기반) |
| `modules/alb/` | ALB, HTTP/HTTPS 리스너, Blue/Green 타겟그룹, Route53 레코드 |
| `modules/codedeploy/` | CodeDeploy 애플리케이션 및 Blue/Green 배포 그룹 |
| `modules/cdn/` | CloudFront 배포, OAI, Route53 레코드(root/www) |
| `modules/s3_static_site/` | 프론트엔드 정적 파일 호스팅용 S3 버킷 (CloudFront 전용 접근) |
| `modules/ecr/` | 컨테이너 이미지 저장용 ECR 리포지토리 |
| `modules/openvpn/` | 관리자 접근용 OpenVPN EC2 인스턴스 |
| `modules/monitoring-ec2/` | 모니터링 서버 EC2 + 전용 IAM/SG (Scouter 등으로 추정) |
| `modules/database-ec2/` | MySQL DB용 EC2 인스턴스 + S3 접근용 전용 IAM |

---

## 3. 카테고리별 파일 분류

### 3-1. 루트 모듈 파일 (main/variables/outputs/providers)
환경별로 `outputs.tf`는 존재하지 않고, `main.tf` / `variables.tf` / `providers.tf` 3종만 존재합니다.

- `environments/dev/main.tf`, `environments/dev/variables.tf`, `environments/dev/providers.tf`
- `environments/dev_kubeadm/main.tf`, `environments/dev_kubeadm/variables.tf`, `environments/dev_kubeadm/providers.tf`
- `environments/prod/main.tf`, `environments/prod/variables.tf`, `environments/prod/providers.tf`

### 3-2. 모듈 목록 (`modules/` 하위, 13개)
alb, asg, cdn, codedeploy, database-ec2, ec2, ecr, iam, monitoring-ec2, network, openvpn, s3_static_site, security_groups

### 3-3. 환경별 설정 파일
- dev: `environments/dev/*`
- dev_kubeadm (실험/신규): `environments/dev_kubeadm/*`
- prod: `environments/prod/*`
- staging은 존재하지 않음

### 3-4. 백엔드 설정 파일 (state 관리)
- `backend/main.tf` — S3(`koco-terraformstate`) + DynamoDB(`koco-terraformstate`) 생성 리소스
- `environments/dev/providers.tf`, `environments/prod/providers.tf`, `environments/dev_kubeadm/providers.tf` — 각 환경이 위 S3 backend를 사용하도록 설정
- ⚠️ **정정**: `key`로 환경이 구분된다고 서술했으나, 실제로는 `environments/dev_kubeadm/providers.tf`의 `backend "s3" { key = "dev/terraform.tfstate" }`가 `environments/dev/providers.tf`와 **완전히 동일한 key**를 사용합니다. 즉 dev_kubeadm과 dev는 key로 구분되지 않고 **동일한 원격 state 파일을 공유**하며, dev_kubeadm을 apply하면 실제 dev 환경의 state를 그대로 읽고 덮어쓰게 되는 state 레벨 충돌 위험이 있습니다. (`prod`만 `prod/terraform.tfstate`로 정상적으로 구분됨)

### 3-5. 변수 파일 (.tfvars)
- `environments/dev/dev.tfvars`
- `environments/dev_kubeadm/dev.tfvars`
- `environments/prod/prod.tfvars`

---

## 4. 모듈 목록 및 담당 AWS 서비스

| 모듈 | 주요 AWS 리소스 | 설명 |
|---|---|---|
| `alb` | `aws_lb`, `aws_lb_listener`(http/https), `aws_lb_target_group`(BlueGreen), `aws_route53_record`(root/www) | 애플리케이션 로드밸런서 및 도메인 연결, Blue/Green 배포용 타겟그룹 |
| `asg` | `aws_autoscaling_group` | 앱 서버 오토스케일링 그룹 (Launch Template + ALB 타겟그룹 연동) |
| `cdn` | `aws_cloudfront_distribution`, `aws_cloudfront_origin_access_identity`, `aws_route53_record`(root/www) | 정적 사이트/오리진 배포용 CDN, S3 전용 접근(OAI), 도메인 레코드 |
| `codedeploy` | `aws_codedeploy_app`, `aws_codedeploy_deployment_group` | Blue/Green 무중단 배포 파이프라인 (ALB/ASG 연동) |
| `ec2` | `aws_launch_template` | WAS(앱 서버) 실행을 위한 Launch Template (ASG에서 참조) |
| `ecr` | `aws_ecr_repository` | 컨테이너 이미지 저장소 |
| `iam` | `aws_iam_role`, `aws_iam_policy`, `aws_iam_role_policy_attachment`, `aws_iam_instance_profile` | CodeDeploy/EC2 공용 권한 (S3, ECR, CodeDeploy, SSM 파라미터 읽기 등) |
| `network` | `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_nat_gateway`, `aws_eip`, `aws_route_table`(+association) | VPC, 퍼블릭/프라이빗(앱/DB) 서브넷, 라우팅 전체 네트워크 기반 |
| `s3` (`s3_static_site`) | `aws_s3_bucket`, `aws_s3_bucket_website_configuration`, `aws_s3_bucket_policy`, `aws_s3_bucket_public_access_block` | 프론트엔드 정적 파일 호스팅, CloudFront OAI를 통한 제한적 접근 |
| `security_groups` | `aws_security_group`(openvpn/alb/app/db) | 계층별 접근 제어를 위한 보안그룹 세트 |
| *(부가 모듈)* `database-ec2` | `aws_instance`(mysql_server), `aws_iam_role`/`policy`/`instance_profile` | DB용 EC2(MySQL) 및 S3 접근 전용 IAM |
| *(부가 모듈)* `monitoring-ec2` | `aws_instance`, `aws_security_group`, `aws_iam_role`/`policy`/`instance_profile` | 모니터링 서버 EC2 (Scouter 등 추정) 및 전용 SG/IAM |
| *(부가 모듈)* `openvpn` | `aws_instance` | 관리자용 VPN 접속 서버 |

> 참고: 요청하신 카테고리 중 `ecr`은 별도 컨테이너 레지스트리 모듈로 존재하며, `s3`는 `s3_static_site`라는 이름으로 존재합니다.

---

## 5. 전체 `.tf` 파일 개수 및 규모

- `.tf` 파일 총 개수: **54개** (`Terraform_Project` 자체 47개 + `Terraform-init` 부가 리소스 7개, `.terraform/` 캐시 디렉토리 제외)
- 전체 `.tf` 라인 수: **약 3,988줄** (`Terraform_Project` 자체 3,501줄 + `Terraform-init` 487줄)
- `.tfvars` 파일: 3개 (dev, dev_kubeadm, prod)
- 모듈 수: 13개 (`modules/` 하위)
- 환경(루트 모듈) 수: 3개 (dev, dev_kubeadm, prod)
- 규모 평가: 중소 규모 IaC 프로젝트. 3-tier 웹 아키텍처(네트워크 → ALB/ASG/EC2 → CodeDeploy Blue/Green) + CDN/정적사이트 + 모니터링/DB/VPN 부가 서버까지 포함한 전형적인 운영급 구성.

### 기타 관찰 사항
- `backend/`는 다른 환경들과 달리 별도 state로 관리되며, 반드시 가장 먼저 apply되어야 하는 부트스트랩 모듈입니다.
- `dev`와 `prod`는 거의 동일한 모듈 조합을 사용하나, `dev_kubeadm`은 `codedeploy`, `asg`, `ec2`, `monitoring-ec2` 모듈을 사용하지 않는 축소 구성입니다(쿠버네티스 기반 실험 환경으로 추정).
- 각 환경 폴더 내 `.terraform/`, `.terraform.lock.hcl`, `terraform.tfstate` 등은 로컬 실행 캐시/상태 파일로, 버전관리 대상에서 제외하는 것이 일반적입니다(`.gitignore` 점검 권장).

---

## 6. `Terraform-init/` — 부가 리소스 저장소

`Terraform_Project` 하위에 위치하지만, `backend "s3"` 블록이 전혀 없고 **로컬 state(`terraform.tfstate`)로만 관리**되는 완전히 별도의 Terraform 루트입니다. `terraform_remote_state` 등을 통한 상호 참조도 없어 `Terraform_Project`의 백엔드(`koco-terraformstate` S3/DynamoDB)와는 무관하게 독립적으로 존재합니다.

| 경로 | 역할 | 상태 |
|---|---|---|
| `s3-buckets/koco-alb-logs/` | ALB 접근 로그 저장용 S3 | apply 실패 — state의 `resources` 배열이 비어있음(0개) |
| `s3-buckets/koco-codedeploy-artifacts/{dev,prod}/` | CodeDeploy 배포 아티팩트 저장용 S3 | 생성 완료 |
| `s3-buckets/koco-frontend-backup/{dev,prod}/` | 프론트엔드 빌드 산출물 백업용 S3 (`s3_static_site`의 정적 호스팅 버킷과는 별개) | 생성 완료 |
| `waf/{dev_waf,prod_waf}/` | CloudFront에 연결되는 WAFv2 WebACL(`secure-waf-dev`/`secure-waf-prod`) | 생성 완료 (단, 일부 규칙은 실효성 없음 — step7 참고) |

> `Terraform_Project`의 3-tier 인프라(네트워크~배포)와 달리, CDN/로그/보안 관련 "부가" 리소스를 담당하며 별도로 관리·apply되는 저장소입니다.
