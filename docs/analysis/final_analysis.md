# 최종 종합 분석: 21-iceT-cloud Terraform 인프라

작성일: 2026-07-04
본 문서는 `step1_구조파악.md` ~ `step7_스토리지_CDN.md` 7개 분석의 종합본이다. 세부 코드·근거는 각 항목의 `[stepN]` 표기를 따라 원본 문서를 참조한다. 9장은 이후 애플리케이션 저장소(`21-iceT-be`, `21-iceT-fe`)를 교차검증해 추가한 내용이다.

---

## 1. Executive Summary

**한 줄 요약**: AWS `ap-northeast-2` 리전에 구축된 3-tier 웹 아키텍처(CloudFront/S3 정적 프론트엔드 + ALB/ASG/EC2 Spring Boot 백엔드 + EC2 MySQL) + CodeDeploy Blue/Green 배포 파이프라인. 인프라 전용 저장소이며 애플리케이션 코드·CI/CD 워크플로는 포함하지 않는다.

**환경 구성**: `dev`, `prod` (완전 병행 운영 중, 모듈 구성 동일) + `dev_kubeadm` (앱 서버를 쿠버네티스로 교체하려는 미완성 실험 환경, git 미커밋 상태이며 `dev`와 다수 리소스를 충돌 위험 수준으로 공유함 — 4장 참고).

**심각도별 발견 사항**: Critical 2건 / High 6건 / Medium 14건 / Low 8건 (총 30건, 6장 리스크 트래커 참고)

**가장 시급한 이슈 5가지**:
1. **DB root 비밀번호 및 OpenVPN 관리자 비밀번호가 동일한 값(`'koco'`)으로 평문 하드코딩**되어 있고, 후자는 git 히스토리에 영구 잔존 — 즉시 자격증명 교체 및 히스토리 정리 필요. `[step6]`
2. **`dev`와 `dev_kubeadm`이 Terraform state key, S3 버킷명, 도메인을 동일하게 공유** — 두 환경을 함께 apply하면 state 덮어쓰기·리소스 충돌 발생. `[step1][step2][step7]`
3. **`openvpn_sg`가 5개 관리 포트를 전부 `0.0.0.0/0`에 개방하면서 동시에 IMDSv2도 미적용**(`http_tokens=optional`) — 프로젝트 내 네트워크 노출도와 메타데이터 방어 수준이 모두 최저인 지점. `[step3][step6]`
4. **WAS EC2 IAM 역할에 `AmazonS3FullAccess`/`AmazonEC2ContainerRegistryFullAccess`/`AWSCodeDeployFullAccess` 3종의 계정 전체 권한 부여** — SG 우회 침해 시 계정 전체 S3/ECR 접근으로 이어질 수 있음. `[step6]`
5. **NAT 게이트웨이 단일 구성(2a 전용)** — 서브넷은 2-AZ로 준비되었으나 아웃바운드 경로는 단일 장애점. `[step3]`

---

## 2. 전체 아키텍처 다이어그램

### 2-1. 트래픽 흐름 (요청 경로 + 관리 접근 + 배포 경로 통합)

```
사용자 브라우저
   │  https://koco.click / www.koco.click
   ▼
Route53 (A-alias)
   ▼
CloudFront ── WAF(WebACL, us-east-1) 연동, TLSv1.2_2021, 지리제한 없음
   │
   ├─ /oauth/*, /api/* (캐시 안 함, Authorization 헤더 전달)
   │        ▼
   │   ALB-Spring 오리진 (⚠ raw DNS 사용, 커스텀 도메인 아님 — 작성자 인지된 미해결 이슈)
   │        ▼
   │   ALB (퍼블릭 서브넷 2-AZ) :443, ssl_policy=ELBSecurityPolicy-2016-08(구버전)
   │        ▼
   │   Target Group "tg-BlueGreen" :8080, health_check=/actuator/health
   │        ▼
   │   ASG (min=max=desired=1, health_check_type=EC2 ⚠ ALB 상태 미반영, 스케일링 정책 없음)
   │        ▼
   │   EC2 (t3.medium, 프라이빗 앱 서브넷, IMDSv2 강제, Docker + CodeDeploy Agent)
   │        │  :3306 (SG 참조만)
   │        ▼
   │   DB EC2 (MySQL, 프라이빗 DB 서브넷, 단일 인스턴스 — 이중화 없음)
   │
   └─ /game/*, 기본 경로 (최대 1일 캐시)
            ▼
      S3 프론트엔드 버킷 (OAI 경유, 퍼블릭 완전 차단, ⚠ 버저닝·암호화 미설정)

[관리자 접근 경로 — 전체 인프라의 단일 신뢰 지점]
0.0.0.0/0 ──(1194/UDP,22,945,443,943 전부 개방 + IMDSv2 미적용)──▶ openvpn_sg
                                                                    ├─(22)──▶ app_sg
                                                                    └─(22,3306)──▶ db_sg

[배포 경로 — 추정, 확정 불가]
(외부 앱 저장소, 미확인) → ECR(app-repo) → CodeDeploy(Blue/Green)
      → Green ASG 임시 생성(COPY_AUTO_SCALING_GROUP) → 즉시 트래픽 전체 전환(대기 0분)
      → Blue 인스턴스 5분 후 자동 종료
```

### 2-2. 모듈 의존성 그래프 (요약)

```
network ─┬─→ security_groups ─┬─→ alb ─┬─→ asg ──→ codedeploy
         │                    │        └────────────┘ (iam.codedeploy_role_arn)
         │                    ├─→ ec2 ──→ asg  (iam.ec2_instance_profile_name)
         │                    ├─→ openvpn
         │                    └─→ database-ec2
         ├─→ monitoring-ec2, alb, asg, openvpn, database-ec2 (서브넷/vpc_id 직접 소비)

iam ──┬─→ ec2 / codedeploy
cdn ──→ s3_static_site   (ecr은 독립, 다른 모듈이 참조하지 않음)
```

`network`가 사실상 모든 컴퓨트/보안 모듈의 최상위 의존 대상이며, 앱 계층은 `iam → ec2 → asg → alb → codedeploy` 선형 체인, `cdn → s3_static_site`는 독립 체인이다. `[step2]`

---

## 3. 인프라 구성 개요

| 항목 | 내용 |
|---|---|
| `.tf` 파일 수 | 54개 (Terraform_Project 47 + Terraform-init 7) |
| 코드 규모 | 약 3,988줄 |
| 모듈 수 | 13개 (`modules/` 하위) |
| 환경(루트 모듈) | 3개: `dev`, `prod`, `dev_kubeadm`(untracked) |
| Provider | `hashicorp/aws ~> 5.92.0`, Terraform `>= 1.0.0`(상한 없음) |
| 리전 | `ap-northeast-2` 고정 (3개 환경 모두 하드코딩) |
| State 관리 | S3(`koco-terraformstate`, 버저닝+AES256) + DynamoDB 락, `backend/`가 별도 부트스트랩 |
| 환경 분리 방식 | Terraform workspace 미사용, 디렉토리 완전 분리 + tfvars 값만 차등 |

**모듈 목록** (13개): `network`, `security_groups`, `iam`, `ec2`, `asg`, `alb`, `codedeploy`, `cdn`, `s3_static_site`, `ecr`, `openvpn`, `monitoring-ec2`, `database-ec2`
`dev`/`prod`는 13개 전부 사용, `dev_kubeadm`은 `codedeploy`/`ec2`/`asg`/`monitoring-ec2` 4개를 제외한 9개만 사용(앱 서버를 K8s로 대체하려는 의도로 추정). `[step1][step2]`

**Terraform-init/** (별도 로컬 state, 백엔드 무관): ALB 로그 버킷(생성 실패), CodeDeploy 아티팩트 버킷(dev/prod), 프론트엔드 빌드 백업 버킷(dev/prod), WAF WebACL(dev/prod) — `Terraform_Project`와 상호 참조 없이 독립 운영. `[step1][step7]`

---

## 4. 환경 비교 매트릭스 (dev / prod / dev_kubeadm)

| 항목 | dev | prod | dev_kubeadm |
|---|---|---|---|
| 모듈 구성 | 13개 전부 | 13개 전부 | 9개 (codedeploy/ec2/asg/monitoring-ec2 제외) |
| VPC CIDR | `10.1.0.0/16` | `10.3.0.0/16` | **`10.1.0.0/16` (dev와 동일)** |
| Backend state key | `dev/terraform.tfstate` | `prod/terraform.tfstate` | **`dev/terraform.tfstate` (dev와 동일 — state 공유/충돌 위험)** |
| ECR repository_name | `app-repo` | **`app-repo` (dev와 동일 — 전역 유일 제약 위반 가능)** | (모듈 미사용 아님, 동일 값 상속) |
| S3 프론트엔드 버킷명 | `dev-koco-front-s3` | `prod-koco-front-s3` | **`dev-koco-front-s3` (dev와 동일)** |
| 도메인(CDN/Route53) | `koco.click` | (별도 prod 도메인) | **`koco.click` (dev와 동일)** |
| Git 추적 상태 | 추적됨 | 추적됨 | **untracked (미커밋)** |

**결론**: `dev_kubeadm`은 네트워크(CIDR)·state·스토리지·도메인 네 축 모두에서 `dev`와 값을 그대로 공유하는 **"`dev`의 미완성 복제본"**이다. 실험 목적이라 하더라도 현재 상태로는 `dev`와 동시에 `apply`할 수 없으며, 상호 배타적으로만 운영되어야 한다. `[step1][step2][step3][step7]`

**환경 분리 일관성 비교** — 같은 프로젝트 안에서도 영역별로 분리 품질이 다르다:

| 영역 | dev/prod 분리 상태 | 근거 |
|---|---|---|
| IAM 리소스명 | ✅ `${env}-` 접두어로 일관되게 분리 | `[step6]` |
| VPC CIDR (dev/prod 간) | ✅ 옥텟으로 분리 (`.1.` vs `.3.`) | `[step3]` |
| ECR 리포지토리명 | ❌ dev/prod 동일 | `[step4]` |
| dev_kubeadm 전반 | ❌ dev와 4개 축 모두 동일 | `[step1][step2][step3][step7]` |

---

## 5. 계층별 설계 요약

### 5-1. 네트워크 (VPC/Subnet/Routing) `[step3]`

- VPC `/16` × 2-AZ(`2a`,`2c`), 퍼블릭/프라이빗-앱/프라이빗-DB 3계층 × 2AZ = 6개 서브넷(`/24`, tfvars 하드코딩).
- IGW 1개(퍼블릭), **NAT 게이트웨이 1개만 생성되어 2a에 고정** — 프라이빗 앱/DB 라우트 테이블은 AZ별로 분리되어 있으나 전부 동일 NAT를 참조. 비용 최적화형 구성이나 **NAT가 단일 장애점(SPOF)**.
- 설계 의도: 퍼블릭(ALB/NAT/OpenVPN) - 프라이빗앱 - 프라이빗DB 3-tier 심층 방어. 네트워크 계층은 2-AZ HA를 지향하나 컴퓨팅/DB 계층에서 그 이점이 활용되지 않음(5-3 참고).

### 5-2. Security Groups `[step3]`

| SG | 정의 위치 | 인바운드 요약 |
|---|---|---|
| `openvpn_sg` | `security_groups` | 1194/UDP, 22, 945, 443, 943 → 전부 `0.0.0.0/0` |
| `alb_sg` | `security_groups` | 80, 443, 8080 → `0.0.0.0/0` |
| `app_sg` | `security_groups` | 80/443/8080 ← `alb_sg`, 22 ← `openvpn_sg` (CIDR 없음, SG 참조만) |
| `db_sg` | `security_groups` | 3306/22 ← `openvpn_sg`, 3306 ← `app_sg` (CIDR 없음) |
| `monitoring_sg` | `monitoring-ec2` (별도 정의) | 9090, 6180, 6100(TCP/UDP), 22 → 전부 `0.0.0.0/0` |

```
0.0.0.0/0 ─(80,443,8080)─▶ alb_sg ─(80,443,8080)─▶ app_sg ─(3306)─▶ db_sg
0.0.0.0/0 ─(1194,22,945,443,943)─▶ openvpn_sg ─(22)─▶ app_sg
                                              └─(22,3306)─▶ db_sg
```

`app_sg`/`db_sg`는 CIDR 없이 SG 참조만 사용하는 모범적 최소 권한 구조. 반면 `openvpn_sg`와 `monitoring_sg`는 관리 포트(SSH 포함)를 전부 `0.0.0.0/0`에 개방 — 이 프로젝트에서 최소 권한 원칙이 일관되게 적용되지 않은 두 예외 지점.

### 5-3. 컴퓨팅 (EC2/ASG/ALB/ECR) `[step4]`

- **EC2**: Launch Template만 생성(t3.medium, Ubuntu22 AMI, IMDSv2 강제). user_data는 Docker+CodeDeploy Agent 설치까지만 수행, 실제 앱 배포는 CodeDeploy 담당.
- **ASG**: `min=max=desired=1` 고정, 스케일링 정책 없음 — 이름과 달리 실질적으로 "단일 인스턴스 self-healing"용. `health_check_type="EC2"`로 설정되어 ALB 타겟그룹 상태(애플리케이션 레벨)를 반영하지 못함.
- **ALB**: 80→443 강제 리다이렉트, `ssl_policy=ELBSecurityPolicy-2016-08`(구버전, CDN 쪽 `TLSv1.2_2021`보다 낙후), 타겟그룹 1개(`tg-BlueGreen`, `/actuator/health` 헬스체크 — Spring Boot 앱으로 추정).
- **ECR**: Terraform 코드상 dev/prod 리포지토리명이 동일(`app-repo`, 4장 참고)하나, 실제 백엔드 CI/CD 파이프라인은 `dev-app-repo`/`prod-app-repo`로 분기해 사용 중임을 교차검증으로 확인(9장). 프로젝트 관계자 확인 결과 실제 운영에서는 dev/prod 이미지가 문제없이 정상 분리·적용되고 있어 운영상 영향은 없으며, Terraform 코드가 실제 리소스명을 반영하지 못하고 있는 IaC 정합성 이슈로 재분류함. `image_tag_mutability=MUTABLE`(롤백 추적성 낮음), `scan_on_push=true`(양호).
- **HA 실태**: 네트워크는 2-AZ 준비, ALB는 관리형이라 자동 대응 가능하나 **ASG 인스턴스가 1대뿐이라 실질적으로 단일 AZ에서만 실행**되고, DB도 단일 EC2로 이중화 없음. "HA 인프라는 있으나 실제 가동은 단일 인스턴스" 상태.

### 5-4. 배포 파이프라인 (CodeDeploy) `[step5]`

- `compute_platform="Server"`, **Blue/Green + `COPY_AUTO_SCALING_GROUP`**(EC2 태그 기반 아님, ASG 기반). 배포 시 Blue ASG를 복제한 임시 Green ASG가 자동 생성됨.
- 트래픽 전환: HTTPS 리스너 단일 경로로 **사전 대기 0분, 즉시 전체 전환**(카나리/사전 검증 경로 없음). Blue 인스턴스는 5분 후 자동 종료.
- 롤백: `DEPLOYMENT_FAILURE`(배포 절차 실패) 시에만 자동 롤백. **CloudWatch 알람 기반 롤백 미구성** — 배포 후 에러율 급증 등은 감지되지 않음.
- **CI/CD 파이프라인 자체가 이 저장소에 존재하지 않음**: GitHub Actions, CodePipeline/CodeBuild, `appspec.yml` 전무. EC2 역할의 `AmazonS3FullAccess`로 미루어 S3 기반 리비전 전달 방식으로 추정되나 확정 불가(8장 참고).
- 종합: 무중단 배포를 위한 인프라적 장치(Blue/Green, 지연 종료)는 갖췄으나, ASG 헬스체크 미연동(5-3)·알람 기반 롤백 부재로 **"인스턴스 교체는 무중단이지만 배포된 코드 자체의 이상은 빠르게 감지되지 않을 수 있는"** 상태.

### 5-5. IAM & 보안 `[step6]`

- IAM 역할이 공용 `iam` 모듈(CodeDeploy, WAS EC2) + `database-ec2`(DB 전용) + `monitoring-ec2`(모니터링 전용) **3곳에 분산**. OpenVPN EC2만 인스턴스 프로파일 없음(최소 권한 관점에서는 오히려 바람직).
- 정교하게 스코프된 정책(DB 백업 S3 버킷 한정, 모니터링 Describe 전용, SSM `/spring/*` 한정)은 최소 권한이 잘 지켜짐.
- 반면 **WAS EC2 역할은 `AmazonS3FullAccess`/`AmazonEC2ContainerRegistryFullAccess`/`AWSCodeDeployFullAccess` 3종의 계정 전체 권한을 보유**하고, `codedeploy_bluegreen_policy`는 `autoscaling:*` 와일드카드 + `Resource="*"` + `iam:PassRole`/`ec2:RunInstances`까지 포함 — SG 계층의 세밀한 최소 권한 설계와 대비되는 약한 고리.
- IAM 리소스명은 `${env}-` 접두어로 dev/prod 분리가 일관됨(4장 표 참고).
- **시크릿 관리 불균일**: Spring 설정은 SSM Parameter Store(`/spring/*`)로 잘 외부화된 반면, **DB root 비밀번호(`'koco'`)와 OpenVPN 관리자 비밀번호(`'koco'`, 동일 값)가 평문 하드코딩** — 전자는 현재 tfvars에 존재, 후자는 삭제됐지만 git 히스토리에 잔존.

### 5-6. 스토리지 & CDN `[step7]`

- **S3**: 프론트엔드 정적 호스팅(`{env}-koco-front-s3`)과 Terraform State(`koco-terraformstate`) 2종만 이 저장소에서 생성. 배포 아티팩트/DB 백업/로그 버킷은 외부 존재를 가정(코드 없음).
- 두 버킷 모두 퍼블릭 액세스 완전 차단, 프론트엔드는 CloudFront OAI만 허용. **State 버킷은 버저닝+AES256 암호화 모두 적용된 반면, 프론트엔드 버킷은 버저닝·암호화 설정이 전혀 없음** — 배포 실수 시 롤백 불가.
- **CDN**: S3(정적)+ALB(API) 이중 오리진, `/oauth/*`·`/api/*`는 캐시 비활성화, 나머지는 최대 1일 캐시. HTTPS 강제 + `TLSv1.2_2021`(ALB보다 최신) + WAF 연동까지 CDN 레벨 보안은 잘 구성됨.
- **알려진 미해결 이슈(작성자 본인 주석 근거)**: ALB 오리진이 원시 DNS 이름 사용 중(커스텀 도메인 alias로 교체 필요), ALB 로그 버킷 연동은 에러로 미완료.
- **레거시 방식**: OAI(OAC 아님), `forwarded_values`(Cache Policy 객체 아님) — 동작은 하나 AWS 최신 권장 방식은 아님.
- **WAF 실효성 혼재**: Rate-limit·AWS 관리형룰(SQLi/XSS)은 실제 차단 활성. 반면 **수동 IP 차단(빈 리스트)과 GeoMatch(block 액션 없음)는 사실상 no-op** — "1차 방어선"이 부분적으로만 작동.
- 캐시 무효화 자동화 없음(8장 참고), 짧은 TTL(1시간)이 완충 역할.

---

## 6. 종합 리스크 트래커

**심각도 기준**
- **Critical**: 자격증명 유출/평문 노출 등 즉시 보안 사고로 이어질 수 있는 항목
- **High**: 서비스 중단·데이터 손실·state/리소스 충돌로 이어질 수 있는 구조적 결함
- **Medium**: 모범 사례에서 벗어났으나 즉각적 장애로 이어지진 않는 항목
- **Low**: 개선하면 좋으나 우선순위가 낮은 항목

| 심각도 | 영역 | 이슈 | 근거 | 영향 | 권장 조치 |
|---|---|---|---|---|---|
| Critical | 시크릿 관리 | DB root 비밀번호(`'koco'`) 평문 하드코딩, dev/prod/dev_kubeadm 전체 tfvars 동일 | step6 | DB 전체 장악 가능, git 이력에 영구 잔존 | SSM SecureString/Secrets Manager로 이전, 비밀번호 즉시 교체 |
| Critical | 시크릿 관리 | OpenVPN 관리자 비밀번호(`'koco'`, DB와 동일 값) — 파일은 삭제됐으나 git 히스토리(HEAD) 잔존 | step6 | VPN 관리자 계정 탈취 시 전체 인프라 접근 허브 장악 | 비밀번호 교체 + `git filter-branch`/BFG로 히스토리 정리 |
| High | 환경 관리 | `dev`와 `dev_kubeadm`이 backend state key 동일(`dev/terraform.tfstate`) | step1, step2 | dev_kubeadm apply 시 dev state 덮어쓰기 | dev_kubeadm 전용 key로 분리하거나 완성 전까지 apply 금지 |
| High | 환경 관리 | `dev`와 `dev_kubeadm`이 S3 버킷명(`dev-koco-front-s3`)·도메인(`koco.click`) 동일 | step7 | 동시 apply 시 버킷/CloudFront alias 충돌 | dev_kubeadm 전용 네이밍 부여 |
| High | 네트워크 | `openvpn_sg` 5개 관리 포트 전부 `0.0.0.0/0` 개방 + IMDSv2 미적용(`http_tokens=optional`) | step3, step6 | 노출도 최대 + 메타데이터 방어 최소, SSRF 통한 자격증명 탈취 위험 | 소스 IP 대역 제한, `http_tokens=required`로 전환 |
| High | 네트워크 | NAT 게이트웨이 단일 구성(2a 전용), 프라이빗 서브넷 전체가 공유 | step3 | 2a 장애 시 2c 프라이빗 서브넷 아웃바운드 전면 마비 | AZ별 NAT+EIP 추가(비용 트레이드오프 명시적 결정 필요) |
| High | IAM | WAS EC2 역할에 `AmazonS3FullAccess`/`ECR FullAccess`/`AWSCodeDeployFullAccess` 3종 부여 | step6 | SG 우회 침해 시 계정 전체 S3/ECR 접근 가능 | 특정 버킷·리포지토리로 스코프 축소 |
| High | IAM | `codedeploy_bluegreen_policy`에 `autoscaling:*`(와일드카드) + `Resource="*"` + `iam:PassRole`/`ec2:RunInstances` | step6 | 임의 인스턴스 프로파일을 임의 EC2에 연결하는 권한 상승 경로 가능 | 필요한 개별 액션만 유지, 와일드카드 제거 |
| Medium | 컴퓨팅 | ASG `health_check_type="EC2"` — ALB 타겟그룹 상태 미반영 | step4, step5 | 앱 프로세스 다운을 ASG가 감지 못함 | `health_check_type="ELB"`로 전환 |
| Medium | 컴퓨팅 | ASG `min=max=desired=1`, 스케일링 정책 없음 | step4 | 트래픽 증가 시 자동 확장 불가, AZ 장애 시 단일 인스턴스 중단 | desired/max 상향 + Target Tracking 정책 추가 |
| Medium | 컴퓨팅 | DB가 단일 EC2 MySQL (RDS Multi-AZ 아님) | step3, step4 | DB 계층 이중화 없음, 단일 장애점 | RDS Multi-AZ 전환 또는 명시적 리스크 수용 |
| Medium | 컴퓨팅 | ECR 리포지토리명이 Terraform 선언(`app-repo`)과 실제 운영 리소스명(`dev-app-repo`/`prod-app-repo`) 간 불일치 | step4, 9장(교차검증: `21-iceT-be/.github/workflows/deploy.yaml`), 프로젝트 관계자 확인(2026-07-04) | 실제 배포에는 영향 없음(dev/prod 이미지 정상 분리·적용 확인됨)이나, Terraform이 실제 사용 중인 ECR을 관리하지 않아 `apply` 시 미사용 리소스가 추가 생성되거나 IaC-실제 인프라 간 참조 오차가 누적될 수 있음 | tfvars `repository_name`을 `${env}-app-repo`로 수정하거나 `terraform import`로 기존 리소스를 state에 편입 |
| Medium | 배포 | CloudWatch 알람 기반 자동 롤백 미구성(`DEPLOYMENT_FAILURE`만) | step5 | 배포 후 에러율 급증 시 자동 대응 없음 | 알람 기반 `auto_rollback_configuration` 이벤트 추가 |
| Medium | 배포 | 트래픽 전환 전 대기시간 0분(`deployment_ready_option.wait_time_in_minutes=0`) | step5 | 사람 개입 없이 즉시 전체 전환, 사전 점검 기회 없음 | 카나리/테스트 리스너 도입 검토 |
| Medium | 스토리지 | 프론트엔드 S3 버킷 버저닝·암호화 미설정 | step7 | 배포 실수 시 롤백 불가 | `aws_s3_bucket_versioning` 활성화 |
| Medium | 스토리지 | `force_destroy`/`lifecycle prevent_destroy` 주석 처리(비활성) | step7 | 실수로 인한 버킷 삭제 방지 장치 없음 | `prevent_destroy=true` 활성화 |
| Medium | 컴퓨팅 | ALB `ssl_policy=ELBSecurityPolicy-2016-08` (구버전, CDN보다 낙후) | step4 | 약한 암호 스위트 허용 가능 | `ELBSecurityPolicy-TLS13-1-2-2021-06` 등으로 갱신 |
| Medium | 네트워크 | `alb_sg`의 8080 포트가 `0.0.0.0/0`에 개방 | step3 | 내부용 포트의 불필요한 외부 노출 가능성 | 실제 필요 여부 확인 후 제거 검토 |
| Medium | 네트워크 | `monitoring_sg` 전체 포트(SSH 포함) `0.0.0.0/0` 개방 | step3 | 모니터링 서버가 openvpn_sg와 동급으로 노출 | 소스 IP 제한 |
| Medium | IAM | 인라인/관리형 정책 방식이 모듈별로 혼재(iam·monitoring은 관리형, database-ec2는 인라인) | step6 | 기능 문제는 없으나 일관성 부족 | 재사용성 필요 여부에 따라 방식 통일 검토 |
| Medium | CDN | ALB 오리진이 raw DNS 이름 사용(커스텀 도메인 alias 아님, 작성자 인지된 이슈) | step7 | ALB 재생성 시 CDN 오리진 단절 가능 | `module.alb.alb_dns_name` output → Route53 alias로 교체 |
| Medium | 모듈 인터페이스 | `cdn` 모듈이 `module.alb` output 대신 `var.*`로 직접 값 수신 | step2 | ALB 재생성 시 CDN이 자동 갱신되지 않음 | output→input 참조로 통일 |
| Low | CDN | WAF 수동 IP 차단(빈 리스트)·GeoMatch(block 없음) 규칙이 사실상 no-op | step7 | 규칙명과 실제 동작 불일치, 오탐 신뢰 위험 | 실제 IP 등록 또는 규칙 제거, GeoMatch에 block 액션 추가 |
| Low | 컴퓨팅 | ECR `image_tag_mutability=MUTABLE` | step4 | 롤백 시 이미지 재현성 저하 | `IMMUTABLE` + 커밋 SHA 태깅 |
| Low | CDN | OAI(OAC 아님), `forwarded_values`(Cache Policy 아님) | step7 | 동작은 하나 최신 권장 방식 아님 | OAC·Cache Policy/Origin Request Policy로 전환 |
| Low | 컴퓨팅 | Docker Compose 1.29.2(구버전 v1 계열) | step4 | 최신 기능/보안 패치 미반영 | Docker Compose v2 플러그인 방식으로 전환 |
| Low | 컴퓨팅 | dev/prod가 동일 키페어(`KoCo_testServer_key`) 공유 | step4 | 키 유출 시 영향 범위 확대 | 환경별 별도 키페어 사용 |
| Low | 구성 관리 | provider 버전이 backend(`5.99.1`)와 환경(`5.92.0`) 간 불일치 | step2 | 버전 드리프트 가능성 | lock 파일 버전 통일 |
| Low | 배포 | `target_group_pair_info`의 두 `target_group` 블록이 동일 이름 중복 선언 | step5 | 불필요한 중복이나 기능 영향 없음(COPY_AUTO_SCALING_GROUP이 실질 처리) | 필요 시 CodeDeploy 문서 기준으로 정리 |
| Low | 구조 | 환경 폴더 내 `.terraform/`, `.terraform.lock.hcl`, `terraform.tfstate` 등 로컬 파일의 `.gitignore` 처리 여부 미확인 | step1 | 민감 정보/불필요 파일이 버전관리에 포함될 가능성 | `.gitignore` 점검 |

---

## 7. 개선 우선순위 로드맵

**즉시 조치 (Critical, 1주 이내)**
- DB root / OpenVPN 관리자 비밀번호 즉시 교체, SSM Secrets Manager로 이전 (`modules/database-ec2`, 관련 tfvars)
- OpenVPN 비밀번호가 포함된 git 히스토리 정리 (`git filter-branch` 또는 BFG)

**단기 (High, 1개월 이내)**
- `dev_kubeadm`의 state key/S3 버킷명/도메인을 `dev`와 분리하거나, 완성 전까지 apply 금지를 팀 규칙으로 명문화 (`environments/dev_kubeadm/*`)
- `openvpn_sg` 인바운드를 관리자 고정 IP 대역으로 제한, `http_tokens=required`로 전환 (`modules/security_groups`, `modules/openvpn/main.tf`)
- NAT 이중화 여부 결정 — 비용 대비 가용성 트레이드오프를 팀 차원에서 명시적으로 검토·결정 (`modules/network`)
- WAS EC2 IAM 정책을 특정 리소스로 스코프 축소, `codedeploy_bluegreen_policy`의 `autoscaling:*` 와일드카드 제거 (`modules/iam`)

**중기 (Medium)**
- ECR 리포지토리명을 실제 운영 중인 `${env}-app-repo`와 일치시키거나 `terraform import`로 기존 리소스를 state에 편입 — 운영 영향은 없으나 IaC 정합성 확보 차원 (`modules/ecr`, `dev.tfvars`/`prod.tfvars`, 9장 참고)
- ASG `health_check_type=ELB` 전환 + CloudWatch 알람 기반 자동 롤백 추가 (`modules/asg`, `modules/codedeploy`)
- 프론트엔드 S3 버저닝/암호화 활성화, `prevent_destroy` 재활성화 (`modules/s3_static_site`)
- ALB SSL 정책 최신화, CDN 오리진을 raw DNS → Route53 alias로 교체 (`modules/alb`, `modules/cdn`)
- `cdn` 모듈 인터페이스를 `module.alb` output 참조 방식으로 통일 (`environments/*/main.tf`)
- DB HA(RDS Multi-AZ) 도입 여부 검토, ASG desired/max 상향 및 스케일링 정책 추가

---

## 8. 확인 불가 영역 (저장소 범위 밖)

다음 항목들은 이 인프라(IaC) 저장소만으로는 확정할 수 없으며, 별도의 애플리케이션 저장소·외부 프로세스·수동 운영 절차를 통해서만 확인 가능하다.

- **CI/CD 트리거 주체**: `appspec.yml`, GitHub Actions, CodePipeline/CodeBuild가 이 저장소에 전혀 없음. 배포가 수동 CLI(`aws deploy create-deployment`)로 실행되는지, 별도 앱 저장소의 CI가 호출하는지 확정 불가. `[step5]`
- **배포 리비전 저장 위치**: EC2 역할의 `AmazonS3FullAccess`로 미루어 S3 기반 리비전 전달로 추정되나, 어느 버킷을 쓰는지·업로드 주체는 확인 불가. `[step5]`
- **IAM 사용자/콘솔 접근 관리**: `aws_iam_user`/`aws_iam_group` 리소스 없음 — 사람의 콘솔 접근(SSO, IAM 사용자 등)은 이 저장소 범위 밖에서 관리되는 것으로 추정. `[step6]`
- **CloudFront 캐시 무효화 자동화 여부**: `aws_cloudfront_invalidation` 리소스나 관련 CLI 호출이 저장소 내에 없음 — 배포 후 무효화가 자동화되어 있는지 확인 불가(짧은 TTL이 완충 역할). `[step7]`
- **배포 아티팩트/DB 백업 버킷의 생성 주체**: `koco-db-backup`, CodeDeploy 아티팩트 버킷은 IAM 정책에서 ARN으로만 참조될 뿐, 버킷 자체를 만드는 Terraform 리소스가 없어 수동 생성 여부만 추정 가능. `[step6][step7]`

---

## 9. 추가 검증 (2026-07-04, 애플리케이션 저장소 교차 확인)

step1~7은 `21-iceT-cloud`(IaC 저장소) 범위만 분석 대상으로 삼았기 때문에, 8장의 여러 항목이 "확인 불가"로 남아 있었다. 이후 백엔드(`21-iceT-be`)·프론트엔드(`21-iceT-fe`) 저장소의 실제 GitHub Actions 워크플로 파일을 직접 확인해 아래 내용을 교차검증했다.

**8장 항목 중 확인 완료로 전환된 사항**

| 8장 항목 | 기존 상태 | 교차 검증 결과 |
|---|---|---|
| CI/CD 트리거 주체 | 확정 불가 | `21-iceT-be`/`21-iceT-fe` 모두 `workflow_dispatch`(수동 트리거)만 사용. push 시 자동 실행되는 CI는 없으며, 백엔드는 배포할 이미지 태그(`image_tag`)를 사람이 직접 입력해야 실행됨. |
| 배포 리비전 저장 위치 | S3 기반으로 추정, 확정 불가 | 확인됨 — `{env}-koco-codedeploy-artifacts` S3 버킷에 `appspec.yml`/`docker-compose.yaml`/`deploy.sh`를 묶은 `spring-app-deploy.zip`을 업로드한 뒤 `aws deploy create-deployment`로 CodeDeploy를 호출. |
| CloudFront 캐시 무효화 자동화 여부 | 확인 불가 | 확인됨 — 프론트엔드 워크플로가 S3 sync 직후 `aws cloudfront create-invalidation --paths "/*"`를 자동 실행. |

**새로 발견된 이슈: ECR 리포지토리 네이밍 — IaC와 실제 파이프라인 간 불일치 (운영 영향 없음, 프로젝트 관계자 확인)**

- Terraform(`modules/ecr/main.tf`: `name = var.repository_name`, `dev.tfvars`/`prod.tfvars` 모두 `repository_name = "app-repo"`)은 dev/prod의 ECR 리포지토리명을 동일하게 생성하도록 되어 있다 — step4 지적 사항을 코드 레벨에서 재확인.
- 그러나 실제 백엔드 배포 워크플로(`21-iceT-be/.github/workflows/deploy.yaml`)는 브랜치(`dev`/그 외)에 따라 `ECR_REPO_NAME`을 `dev-app-repo` 또는 `prod-app-repo`로 분기해 이미지를 빌드·푸시한다.
- 즉 **Terraform이 생성·관리한다고 선언한 리소스명(`app-repo`)과 실제 운영 중인 CI/CD가 사용하는 리소스명(`dev-app-repo`/`prod-app-repo`)이 서로 다르다.**
- **2026-07-04, 프로젝트 관계자 확인**: 실제 운영에서는 `dev-app-repo`/`prod-app-repo`가 이미 정상적으로 존재하며, dev/prod 이미지가 문제없이 정확히 분리·적용되고 있다. 즉 앞서 제시했던 두 해석 중 "①번 — `dev-app-repo`/`prod-app-repo`가 Terraform 외부에서 이미 운영되고 있고, Terraform `ecr` 모듈이 생성하는 `app-repo`는 실제로 쓰이지 않는 리소스"가 맞는 것으로 확인되었다. 배포 파이프라인 자체의 결함이나 리소스 충돌이 아니라, **Terraform 코드가 실제로 운영 중인 ECR 리소스를 관리 대상으로 포함하지 못하고 있는 IaC 정합성(source of truth) 이슈**로 성격이 좁혀진다.
- 이에 따라 6장 리스크 트래커의 해당 항목은 기존 High에서 Medium으로 하향 조정했다 — 서비스 장애·데이터 손실로 이어지는 구조적 결함이 아니라, IaC가 실제 인프라를 정확히 추적하지 못하는 모범 사례 이탈 항목이기 때문이다. 다만 향후 `apply` 시 `app-repo`라는 미사용 리소스가 실제로 생성되거나, IaC 문서만 보고 인프라를 파악하려는 사람에게 혼동을 줄 수 있어 개선 과제로는 유지한다.

---

## 부록: 근거 매핑표

| 최종 문서 섹션 | 원본 근거 |
|---|---|
| 2장 아키텍처 다이어그램 | step4 §5(트래픽 흐름) + step7 §3(CDN 흐름) + step3 §3-3(SG 참조) 병합 |
| 3장 인프라 구성 개요 | step1 §1~5 압축 |
| 4장 환경 비교 매트릭스 | step1 §3-4·§6, step2 §6, step3 §1-1, step4 §4-1, step7 §4-3 |
| 5-1 네트워크 | step3 §1~2, §4 |
| 5-2 Security Groups | step3 §3 |
| 5-3 컴퓨팅 | step4 §1~5 |
| 5-4 배포 파이프라인 | step5 §1~4 |
| 5-5 IAM & 보안 | step6 §1~5 |
| 5-6 스토리지 & CDN | step7 §1~4 |
| 6장 리스크 트래커 | step1~7 전체에서 "⚠️" 표기 항목 전량 취합 |
| 8장 확인 불가 영역 | step5 §3, step6 §3, step7 §3-2·§1-1 |
| 9장 추가 검증 | `21-iceT-be`(`.github/workflows/deploy.yaml`, `scripts/deploy.sh`) · `21-iceT-fe`(`.github/workflows/frontend-deploy-s3.yaml`) 실제 파일 확인(2026-07-04) |
