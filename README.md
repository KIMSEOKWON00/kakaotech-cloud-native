# 🧊 iceT-cloud Infrastructure

**AWS 기반 3-tier 웹 서비스 인프라를, Terraform 모듈로 설계·구축한 IaC 프로젝트**

CloudFront/S3 정적 프론트엔드 + ALB/ASG/EC2 Spring Boot 백엔드 + CodeDeploy Blue/Green 무중단 배포까지, 하나의 서비스가 운영되기 위해 필요한 네트워크 · 컴퓨팅 · 배포 · 보안 · 스토리지 계층 전체를 13개의 재사용 가능한 Terraform 모듈로 구성했습니다.

---

## 목차

- [한 줄 소개](#한-줄-소개)
- [전체 인프라 아키텍처](#전체-인프라-아키텍처)
- [사용 AWS 서비스](#사용-aws-서비스)
- [Terraform 모듈 구조](#terraform-모듈-구조)
- [네트워크 설계 (VPC/서브넷)](#네트워크-설계-vpc서브넷)
- [배포 파이프라인](#배포-파이프라인)
- [IAM 및 보안 설계](#iam-및-보안-설계)
- [스토리지 및 CDN 구성](#스토리지-및-cdn-구성)
- [실행 방법](#실행-방법)
- [발표자료](#발표자료)
- [관련 저장소](#관련-저장소)
- [프로젝트에서 다룬 핵심 기술적 의사결정](#프로젝트에서-다룬-핵심-기술적-의사결정)

---

## 한 줄 소개

> **"코드 하나로 dev/prod 환경을 동시에 재현하는 3-tier AWS 인프라"** — VPC부터 Blue/Green 배포, WAF까지 Terraform으로 선언한 인프라 저장소입니다.

---

## 전체 인프라 아키텍처

```
사용자 브라우저
   │  HTTPS
   ▼
Route53 (A-alias)
   ▼
CloudFront (CDN) ── WAF 연동 (Rate-limit / SQLi·XSS 차단)
   │
   ├─ /oauth/*, /api/* (캐시 없음, 즉시 오리진 전달)
   │        ▼
   │   ALB (80→443 리다이렉트)
   │        ▼
   │   Target Group "tg-BlueGreen" :8080 (health check: /actuator/health)
   │        ▼
   │   ASG (프라이빗 앱 서브넷 2-AZ에 배치 가능, 현재 desired=max=min=1 → 실 가동 1대)
   │        ▼
   │   EC2 (Docker + CodeDeploy Agent)
   │        │  :3306 (SG 참조만, CIDR 없음)
   │        ▼
   │   DB EC2 (MySQL, 프라이빗 DB 서브넷, 단일 인스턴스)
   │
   └─ /game/*, 기본 경로 (최대 1일 캐시)
            ▼
      S3 (정적 프론트엔드, OAI 경유, 퍼블릭 완전 차단)

[관리자 접근 경로 — 전체 인프라의 단일 진입점]
0.0.0.0/0 ──▶ OpenVPN EC2 ──(22)────────▶ App 서버
                          └─(22, 3306)──▶ DB 서버

[배포 경로 — CodeDeploy Blue/Green]
GitHub Actions(수동 트리거) → Docker Build/Push → ECR({env}-app-repo)
      → S3(배포 아티팩트) → CodeDeploy ──▶ Green ASG 임시 생성 (COPY_AUTO_SCALING_GROUP)
      → 트래픽 즉시 전체 전환(wait_time=0) → Blue 인스턴스 5분 후 자동 종료
```

**3-tier 심층 방어(Defense in Depth) 설계**: 퍼블릭(ALB/NAT/OpenVPN) → 프라이빗 앱 → 프라이빗 DB로 계층을 분리하고, 앱/DB 보안그룹은 CIDR 없이 오직 보안그룹 참조(SG-to-SG)만 허용해 두 계층 모두 인터넷에서 직접 도달할 수 없도록 설계했습니다.

> 참고: ASG는 프라이빗 앱 서브넷 2개 AZ 어디에나 배치될 수 있도록 구성되어 있으나, 현재는 비용 절감을 위해 `desired=max=min=1`로 운영 중이라 실제 가동 인스턴스는 1대입니다. 트래픽 증가 시 `max_size` 상향과 스케일링 정책 추가로 실질적인 다중 AZ 이중화를 도입할 수 있는 구조입니다.
>
> 참고: ECR은 브랜치에 따라 `dev-app-repo`/`prod-app-repo`로 이미지가 분리·적용되고 있습니다.

---

## 사용 AWS 서비스

| 영역 | 서비스 | 역할 |
|---|---|---|
| 네트워크 | `VPC` `Subnet` `IGW` `NAT Gateway` `Route Table` | 2-AZ(2a/2c) 기반 3계층(퍼블릭/프라이빗-앱/프라이빗-DB) 네트워크 |
| 컴퓨팅 | `EC2` `Auto Scaling Group` `Launch Template` | Spring Boot 앱 서버(WAS), IMDSv2 강제 |
| 로드밸런싱 | `Application Load Balancer` | HTTPS 종료, Blue/Green 타겟그룹 라우팅 |
| 배포 | `CodeDeploy` `ECR` | Blue/Green 무중단 배포, 컨테이너 이미지 저장 |
| CDN/스토리지 | `CloudFront` `S3` `Route53` | 정적 사이트 호스팅, 엣지 캐싱, 도메인 관리 |
| 보안 | `WAF` `Security Group` `IAM` `ACM` | 웹 방화벽, 네트워크/권한 이중 방어, TLS 인증서 |
| 관리 | `OpenVPN(EC2)` `모니터링 EC2`(Scouter/Prometheus) | 관리자 원격 접근, 자체 구축 인프라 모니터링 |
| 상태 관리 | `S3` `DynamoDB` | Terraform 원격 state 저장 및 동시 실행 락 |

---

## Terraform 모듈 구조

디렉토리 기반 환경 분리(`dev` / `prod` / `dev_kubeadm`) + 13개 재사용 모듈 조합 방식을 사용합니다. 환경 간 코드는 동일하게 유지하고, 값(`*.tfvars`)만 분리하는 **"코드 공유 + 값만 분리"** 전략입니다.

```
Terraform_Project
├── backend/                 # Terraform state용 S3 + DynamoDB (최초 1회 부트스트랩)
├── environments/
│   ├── dev/                 # 개발 환경 (13개 모듈 전부 사용)
│   ├── prod/                # 운영 환경 (13개 모듈 전부 사용, 값만 dev와 차등)
│   └── dev_kubeadm/         # 앱 서버를 K8s로 대체하는 환경 (9개 모듈)
└── modules/
    ├── network              # VPC/Subnet/IGW/NAT/Route Table
    ├── security_groups      # openvpn/alb/app/db 보안그룹
    ├── iam                  # CodeDeploy/EC2 공용 IAM
    ├── ec2                  # WAS Launch Template
    ├── asg                  # Auto Scaling Group
    ├── alb                  # ALB, 리스너, Blue/Green 타겟그룹
    ├── codedeploy           # CodeDeploy App/Deployment Group
    ├── ecr                  # 컨테이너 이미지 저장소
    ├── cdn                  # CloudFront, OAI, Route53
    ├── s3_static_site       # 프론트엔드 정적 호스팅 S3
    ├── database-ec2         # DB(MySQL) EC2 + 전용 IAM
    ├── monitoring-ec2       # 모니터링 서버 EC2 + 전용 SG/IAM
    └── openvpn              # 관리자 접근용 VPN 서버
```

> `Terraform_Project`와 별도로 `Terraform-init/`(로컬 state)에서 WAF WebACL, CodeDeploy 아티팩트 버킷, 프론트엔드 빌드 백업 버킷을 독립적으로 관리합니다.

**모듈 의존성 그래프**

```
network ─┬─→ security_groups ─┬─→ alb ─┬─→ asg ──→ codedeploy
         │                    │        └────────────┘
         │                    ├─→ ec2 ──→ asg
         │                    ├─→ openvpn
         │                    └─→ database-ec2
         └─→ monitoring-ec2, alb, asg, openvpn, database-ec2

iam ──┬─→ ec2 / codedeploy
cdn ──→ s3_static_site   (ecr은 독립 모듈)
```

`network`가 모든 컴퓨팅/보안 모듈의 최상위 의존 대상이며, 앱 계층은 `iam → ec2 → asg → alb → codedeploy`로 이어지는 선형 체인, `cdn → s3_static_site`는 별도의 독립 체인으로 구성했습니다.

**규모**: `.tf` 파일 54개(약 3,988줄), 모듈 13개, 환경 3개 · Provider `hashicorp/aws ~> 5.92.0` · 리전 `ap-northeast-2` 고정 · State는 S3(`koco-terraformstate`, 버저닝+AES256) + DynamoDB 락으로 관리.

---

## 네트워크 설계 (VPC/서브넷)

| 환경 | VPC CIDR | AZ | 서브넷 구성 |
|---|---|---|---|
| dev | `10.1.0.0/16` | `2a`, `2c` | 퍼블릭 ×2, 프라이빗-앱 ×2, 프라이빗-DB ×2 (`/24`) |
| prod | `10.3.0.0/16` | `2a`, `2c` | 동일 구조 |

```
VPC (/16)
├── Public Subnet (2a, 2c)       ─ ALB, NAT Gateway, OpenVPN
├── Private-App Subnet (2a, 2c)  ─ EC2(WAS), 모니터링 서버
└── Private-DB Subnet (2a, 2c)   ─ EC2(MySQL)
```

**설계 의도**
- 앱과 DB를 같은 "프라이빗"으로 묶지 않고 계층을 한 번 더 나눔으로써, 앱 서버가 침해당해도 DB 접근에는 추가 보안그룹 경계(`app_sg → db_sg`)를 거치도록 하는 심층 방어 구조입니다.
- 보안그룹은 `alb_sg → app_sg → db_sg`로 이어지는 SG-to-SG 참조만 사용하고, 앱/DB 서버에는 CIDR 기반 인바운드가 전혀 없어 인터넷에서 직접 도달할 수 없습니다.
- 관리자 접근은 `openvpn_sg` 하나로 집중시켜, VPN을 거치지 않고는 SSH로 어떤 서버에도 접근할 수 없는 단일 관리 경로(single admin entrypoint)를 구성했습니다.
- 비용 최적화를 위해 NAT Gateway는 2a 가용영역(AZ)에 1개만 배치했습니다 — 평시 비용을 절감하는 대신 2a 장애 시 2c 프라이빗 서브넷의 아웃바운드 통신도 함께 영향받을 수 있는 단일 장애점(SPOF)을 감수한 것으로, 트래픽/가용성 요구가 커지면 AZ별 NAT 이중화로 전환할 수 있도록 라우트 테이블은 이미 AZ별로 분리해 두었습니다.

---

## 배포 파이프라인

이 저장소는 인프라(IaC) 전용이며, 애플리케이션 빌드·배포는 백엔드/프론트엔드/AI 저장소의 GitHub Actions가 담당합니다. 아래는 Terraform이 구성한 CodeDeploy Blue/Green 인프라와, 실제 배포를 트리거하는 세 애플리케이션 저장소의 워크플로를 함께 정리한 것입니다(2026-07-04 기준 실제 워크플로 파일을 직접 확인해 작성).

### CodeDeploy Blue/Green (인프라 레벨)

```
ECR({env}-app-repo, scan_on_push)   ※ Terraform 선언명은 아직 app-repo(정리 예정), 실제 운영명은 이 이름
        │
        ▼
CodeDeploy (compute_platform=Server, BLUE_GREEN)
        │  COPY_AUTO_SCALING_GROUP
        ▼
Blue ASG(운영 중) ──── 복제 ────▶ Green ASG(신규 생성)
        │                              │
        │                    EC2 부팅 → CodeDeploy Agent →
        │                    Docker 컨테이너 기동
        │                              │
        └──────── 트래픽 전환(HTTPS 리스너) ◀───┘
                          │
                          ▼
              Blue 인스턴스 5분 대기 후 자동 종료
```

**왜 Blue/Green인가**: In-place 배포 대신 ASG 자체를 복제하는 방식을 택해, 신규 버전이 완전히 기동을 마칠 때까지 기존 버전이 트래픽을 계속 처리하도록 설계했습니다. 배포 성공 후에도 Blue 인스턴스를 즉시 삭제하지 않고 5분의 유예시간을 두어, 전환 직후 문제 발생 시 대응할 시간을 확보했습니다.

- EC2 태그가 아닌 **ASG 기반**(`autoscaling_groups`) 배포 대상 지정
- 자동 롤백은 `DEPLOYMENT_FAILURE`(배포 절차 실패) 조건으로 구성

### 백엔드 CI/CD — [`21-iceT-be`](https://github.com/100-hours-a-week/21-iceT-be)

```
GitHub Actions (workflow_dispatch, image_tag 수동 입력)
        │
        ▼
Docker Build → ECR 푸시 ({env}-app-repo:{image_tag} / :latest 동시 태깅)
        │
        ▼
appspec.yml / docker-compose.yaml / deploy.sh 동적 생성
        │
        ▼
zip 압축 → S3 업로드 ({env}-koco-codedeploy-artifacts)
        │
        ▼
aws deploy create-deployment (CodeDeployDefault.AllAtOnce)
        │
        ▼
CodeDeploy Blue/Green 배포 시작 (위 인프라 흐름으로 이어짐)
```

- 트리거: [`deploy.yaml`](https://github.com/100-hours-a-week/21-iceT-be/blob/main/.github/workflows/deploy.yaml) — push 시 자동 실행이 아닌 **`workflow_dispatch` 수동 트리거**로, 배포할 이미지 태그를 사람이 직접 입력해 원치 않는 배포를 방지합니다.
- 브랜치(`dev` / 그 외)에 따라 ECR 리포지토리명(`dev-app-repo`/`prod-app-repo`), S3 아티팩트 버킷, SSM 파라미터 경로(`/spring/{env}/`), CodeDeploy 앱·배포 그룹 이름을 모두 자동 분기해, 워크플로 하나로 dev/prod 배포를 함께 처리합니다.
- EC2에서 실행될 [`deploy.sh`](https://github.com/100-hours-a-week/21-iceT-be/blob/main/scripts/deploy.sh)는 워크플로가 빌드 시점에 동적으로 재생성하며, SSM Parameter Store 값을 `.env`로 변환한 뒤 최신 이미지를 pull해 `docker compose up -d`로 기동합니다.
- CodeDeploy의 배치 방식(`CodeDeployDefault.AllAtOnce`)은 Terraform이 아니라 이 워크플로의 `aws deploy create-deployment` 호출 시점에 지정됩니다 — 인프라(Terraform)와 배포 실행(GitHub Actions)의 책임이 명확히 분리되어 있습니다.

### 프론트엔드 CI/CD — [`21-iceT-fe`](https://github.com/100-hours-a-week/21-iceT-fe)

```
GitHub Actions (workflow_dispatch)
        │
        ▼
npm run build (브랜치별 Vite 환경변수 주입 — API_BASE_URL, 카카오 OAuth 등)
        │
        ▼
S3 정적 호스팅 버킷 동기화 (aws s3 sync --delete)
        │
        ▼
빌드 산출물 타임스탬프 백업 (S3 backup 버킷)
        │
        ▼
CloudFront 캐시 무효화 (aws cloudfront create-invalidation --paths "/*")
```

- 트리거: [`frontend-deploy-s3.yaml`](https://github.com/100-hours-a-week/21-iceT-fe/blob/main/.github/workflows/frontend-deploy-s3.yaml) — 백엔드와 동일하게 `workflow_dispatch` 수동 트리거입니다.
- `main` 브랜치는 `ktbkoco.com` 도메인 · `prod-koco-front-s3` 버킷, 그 외 브랜치는 `koco.click` 도메인 · `dev-koco-front-s3` 버킷으로 자동 분기됩니다.
- 배포 직후 **CloudFront invalidation을 자동 실행**해, 캐시 TTL(최대 1일)과 무관하게 배포 즉시 최신 정적 파일이 반영되도록 합니다.

### AI(챗봇) CI/CD — [`21-iceT-ai`](https://github.com/100-hours-a-week/21-iceT-ai)

```
GitHub Actions (push → `feat/2-chatbot` 브랜치, 또는 workflow_dispatch)
        │
        ▼
Docker Build (src/solchat/Dockerfile) → ECR 푸시 (:latest 단일 태그)
        │
        ▼
AWS SSM send-command (AWS-RunShellScript, 대상: EC2_INSTANCE_ID)
        │
        ▼
EC2 내부에서 직접 실행:
  ECR 로그인 → 8000 포트/`chatbot-api`/`ai` 기존 컨테이너 stop·rm
  → 최신 이미지 pull → docker run -d -p 8000:8000 --name chatbot-api
```

- 트리거: [`deploy.yaml`](https://github.com/100-hours-a-week/21-iceT-ai/blob/dev/.github/workflows/deploy.yaml) — `feat/2-chatbot` 브랜치 **push 시 자동 실행** + `workflow_dispatch` 수동 실행을 모두 지원합니다. be/fe가 수동 트리거만 허용하는 것과는 다른 방식입니다.
- 배포 방식: CodeDeploy Blue/Green이 아니라 **AWS SSM(`RunShellScript`)으로 EC2에 직접 접속해 `docker stop/rm/run`을 실행하는 인플레이스(in-place) 배포**입니다. Green 환경 생성이나 트래픽 전환 유예, 자동 롤백 없이 컨테이너를 즉시 교체합니다.
- 이미지 태그: 커밋/수동 태그 구분 없이 `:latest` 고정 — be가 배포 시점마다 `image_tag`를 사람이 입력하는 것과 달리 항상 최신 이미지로 덮어씁니다.
- 런타임 설정은 이미지에 포함하지 않고, GitHub Secrets에 저장된 `.env`/`gcp_key.json`을 워크플로 실행 시점에 파일로 복원해 주입합니다.
- 이 워크플로가 대상으로 하는 `EC2_INSTANCE_ID`는 `Terraform_Project`의 13개 모듈(`ec2`/`asg`/`monitoring-ec2` 등) 중 AI 전용 모듈에 대응하지 않습니다. 즉 AI 서비스가 배포되는 EC2는 본 저장소(`21-iceT-cloud`)가 Terraform으로 프로비저닝·관리하는 리소스 범위에 포함되어 있지 않습니다.

---

## IAM 및 보안 설계

**네트워크(SG) × 권한(IAM) 이중 방어 구조**로, 서비스별 EC2가 각각 자신의 보안그룹과 IAM 역할을 짝으로 갖습니다.

| 서비스 | 보안그룹 | IAM 역할 | 권한 범위 |
|---|---|---|---|
| WAS(앱) EC2 | `app_sg` (SG 참조만) | `ec2_role` | SSM(`/spring/*`)은 정확히 스코프, S3·ECR·CodeDeploy는 현재 AWS 관리형 FullAccess 정책 사용 중 |
| DB EC2 | `db_sg` (SG 참조만) | `ec2_s3_access` | DB 백업 버킷 1개로 정확히 스코프 |
| 모니터링 EC2 | `monitoring_sg` | `monitoring_ec2_sd_role` | `Describe*` 읽기 전용 |
| OpenVPN EC2 | `openvpn_sg` (`0.0.0.0/0`) | 없음 | 인스턴스 프로파일 미부여(최소 권한) |

**설계 원칙**
- 애플리케이션 설정(DB 접속 정보 등)은 SSM Parameter Store(`/spring/*`)로 외부화해, 코드/이미지에 시크릿을 하드코딩하지 않는 패턴을 적용했습니다.
- IAM 리소스명은 전 영역에서 `${env}-` 접두어로 dev/prod를 분리해, 리소스 충돌 없이 환경을 완전히 독립적으로 운영할 수 있도록 설계했습니다.
- 모든 WAS/DB/모니터링 EC2에 `IMDSv2(http_tokens=required)`를 강제해 SSRF를 통한 메타데이터 탈취 공격에 대응했습니다.
- ACM 인증서는 리전별 요구사항에 맞춰 정확히 분리했습니다 — ALB용은 `ap-northeast-2`(서울), CloudFront용은 `us-east-1`(버지니아, AWS 필수 요구사항).
- **개선 진행 중인 부분**: SSM 스코프 권한과 달리 WAS EC2의 S3/ECR/CodeDeploy 권한은 아직 AWS 관리형 FullAccess 정책에 의존하고 있어, 계정 전체 리소스 대신 특정 버킷·리포지토리로 스코프를 좁히는 작업을 다음 개선 과제로 진행 중입니다. 또한 `openvpn_sg`·`monitoring_sg`는 관리 편의를 위해 현재 관리 포트를 `0.0.0.0/0`에 개방해 두었으며, 향후 관리자 고정 IP 대역으로 제한 가능합니다.

---

## 스토리지 및 CDN 구성

```
사용자 ── Route53 ── CloudFront ── WAF
                          │
              ┌───────────┴────────────┐
        /oauth/*, /api/*          그 외 경로
        (캐시 0, 즉시 전달)         (최대 1일 캐시)
              │                        │
              ▼                        ▼
         ALB 오리진               S3 오리진 (OAI)
    (TLSv1.2, https-only)      (퍼블릭 액세스 완전 차단)
```

- **이중 오리진 단일 도메인**: 정적 프론트엔드(S3)와 백엔드 API(ALB)를 하나의 CloudFront 배포·하나의 도메인으로 통합해, 별도 API 서브도메인 없이 CORS 이슈를 원천 차단하는 구조를 택했습니다.
- **S3 완전 비공개 + OAI**: 프론트엔드 버킷은 퍼블릭 액세스를 4개 옵션 전부 차단하고, CloudFront Origin Access Identity의 IAM ARN만 버킷 정책에서 허용해 S3 URL 직접 접근을 막았습니다.
- **경로 기반 캐시 전략**: `/oauth/*`·`/api/*`는 TTL 0으로 캐시를 완전히 비활성화해 인증/동적 응답의 정합성을 보장하고, 정적 자원은 최대 1일 캐시로 CDN의 성능 이점을 확보했습니다.
- **WAF 다층 방어**: Rate-limit(5분당 IP 1000회 제한)과 AWS 관리형 룰(SQLi/XSS 차단)을 CloudFront 앞단에 연동해, 애플리케이션 계층 이전에 1차 방어선을 구성했습니다. 현재는 이 두 규칙만 실제 차단을 수행하며, 수동 IP 차단·GeoMatch 규칙은 운영 데이터 축적 후 활성화할 예정으로 틀을 먼저 마련해 둔 상태입니다.
- Terraform State 버킷은 버저닝 + AES256 암호화를 모두 적용해, 인프라의 "진실 공급원(source of truth)" 자체를 안전하게 보호하고 있습니다. 다만 프론트엔드 정적 호스팅 버킷은 아직 버저닝·암호화가 적용되어 있지 않아, State 버킷과 동일한 수준으로 맞추는 개선 여지가 있습니다.

---

## 실행 방법

### 사전 조건
- Terraform `>= 1.0.0`
- AWS CLI 인증 설정 완료 (`aws configure` 또는 IAM Role)
- `ap-northeast-2` 리전 접근 권한

### 1) 백엔드(State 저장소) 최초 1회 생성

```bash
cd Terraform_Project/backend
terraform init
terraform apply
```

### 2) 환경별 인프라 배포 (dev 예시)

```bash
cd Terraform_Project/environments/dev
terraform init
terraform plan -var-file="dev.tfvars"
terraform apply -var-file="dev.tfvars"
```

prod 배포 시에는 `environments/prod` 디렉토리에서 동일하게 `-var-file="prod.tfvars"`를 사용합니다.

> ⚠️ `dev_kubeadm` 환경은 `dev`와 VPC CIDR·State Key·S3 버킷명·도메인을 공유하는 실험 환경이므로, `dev`와 동시에 `apply`하지 않아야 합니다.

### 3) 배포 결과 확인

현재 각 환경(`environments/{dev,prod,dev_kubeadm}`)에는 별도의 `outputs.tf`가 없어 `terraform output`으로는 값을 조회할 수 없습니다. 대신 AWS CLI 또는 콘솔에서 확인합니다.

```bash
aws elbv2 describe-load-balancers --names dev-alb --query 'LoadBalancers[0].DNSName'
aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='dev'].DomainName"
```

### 4) 리소스 정리

```bash
terraform destroy -var-file="dev.tfvars"
```

---

## 발표자료

[프로젝트 발표 슬라이드](./docs/presentation.pdf)

---

## 관련 저장소

| 저장소 | 역할 |
|---|---|
| [`21-iceT-be`](https://github.com/100-hours-a-week/21-iceT-be) | Spring Boot 백엔드 + CodeDeploy 배포 워크플로 |
| [`21-iceT-fe`](https://github.com/100-hours-a-week/21-iceT-fe) | React 프론트엔드 + S3/CloudFront 배포 워크플로 |
| [`21-iceT-ai`](https://github.com/100-hours-a-week/21-iceT-ai) | AI 챗봇 서비스 + SSM 기반 EC2 배포 워크플로 |

---

## 프로젝트에서 다룬 핵심 기술적 의사결정

- **디렉토리 기반 환경 분리**를 택해(Terraform Workspace 미사용) 환경별 state를 물리적으로 완전히 격리하고, 코드는 공유하되 값(tfvars)만 환경별로 관리했습니다.
- **Blue/Green + ASG 복제 방식**을 선택해, 트래픽 전환 전 새 버전이 완전히 기동을 마칠 때까지 기다리는 무중단 배포를 구현했습니다.
- **CDN 단일 도메인 통합 아키텍처**로 프론트엔드와 백엔드 API의 CORS 문제를 설계 단계에서부터 제거했습니다.
- **네트워크(SG) + 권한(IAM) 이중 방어**로, 한 계층이 뚫리더라도 다른 계층이 추가 방어선이 되도록 서비스별 보안 경계를 이중화했습니다.
- **인프라(Terraform)와 배포 실행(GitHub Actions)의 책임 분리**: 인프라는 CodeDeploy Blue/Green 골격만 준비하고, 실제 배포 트리거·배치 전략(`AllAtOnce`)·이미지 태깅은 애플리케이션 저장소의 워크플로가 담당하도록 역할을 나눴습니다.
