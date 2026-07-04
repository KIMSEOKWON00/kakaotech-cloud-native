# Step 6. IAM & 보안 설계 분석

작성일: 2026-07-04
대상: `Terraform_Project/modules/iam/*`, `modules/database-ec2/*`, `modules/monitoring-ec2/*`, `modules/openvpn/*`, `environments/{dev,prod}/*.tfvars`, `environments/{dev,prod}/main.tf`, git 히스토리(`git show HEAD:.../openvpn-setup.sh`)

---

## 0. 개요 — IAM 관련 리소스가 흩어져 있는 구조

이 프로젝트는 IAM 역할이 하나의 공용 `iam` 모듈에만 있는 것이 아니라, **3곳에 분산**되어 정의되어 있습니다.

| 위치 | 대상 | 역할(Role) 수 |
|---|---|---|
| `modules/iam/` | 공용 — CodeDeploy 서비스, WAS(앱) EC2 | 2개 |
| `modules/database-ec2/` | DB용 EC2(MySQL) 전용 | 1개 |
| `modules/monitoring-ec2/` | 모니터링 서버 EC2 전용 | 1개 |

즉 "공용 IAM 모듈 1개로 전체 관리"가 아니라, **서비스별 EC2 모듈이 자기 몫의 IAM 리소스를 직접 소유**하는 방식입니다. `database-ec2`, `monitoring-ec2`는 `outputs.tf`조차 없어(step1 참고), IAM 산출물을 모듈 밖으로 공개하지 않고 모듈 내부에서만 소비합니다.

---

## 1. IAM 역할(Role) 목록

| 역할명(tfvars 값, env 접두사 적용 전) | 위치 | Trust(AssumeRole 주체) | 용도 |
|---|---|---|---|
| `CodeDeployServiceRole` | `modules/iam` | `codedeploy.amazonaws.com` | CodeDeploy 서비스 역할 — Blue/Green 배포 시 ASG/ALB 제어 |
| `MyEC2Role` | `modules/iam` | `ec2.amazonaws.com` | **WAS(앱) EC2 인스턴스 프로파일** — S3/ECR/CodeDeploy Agent/SSM 접근 |
| `ec2-s3-access-role` | `modules/database-ec2` | `ec2.amazonaws.com` | **DB(MySQL) EC2 인스턴스 프로파일** — DB 백업 S3 버킷 전용 접근 |
| `monitoring-ec2-sd-role` | `modules/monitoring-ec2` | `ec2.amazonaws.com` | **모니터링 서버 EC2 인스턴스 프로파일** — EC2 서비스 디스커버리(Prometheus 등) |

### 1-1. EC2 인스턴스 프로파일

3개의 서로 다른 EC2 역할군이 각각 별도의 `aws_iam_instance_profile`을 갖습니다.

| 인스턴스 프로파일 | 연결된 역할 | 사용처 |
|---|---|---|
| `MyEC2InstanceProfile` | `ec2_role` | WAS(앱) Launch Template (`modules/ec2/main.tf`) |
| `ec2-s3-access-profile` | `ec2_s3_access` | DB EC2 (`modules/database-ec2/main.tf`) |
| `monitoring-instance-profile` | `monitoring_ec2_sd_role` | 모니터링 EC2 (`modules/monitoring-ec2/main.tf`) |

- OpenVPN EC2(`modules/openvpn`)만 유일하게 **인스턴스 프로파일이 없음** — 별도 IAM 권한 없이 순수 접속 서버로만 동작하는 것으로 보입니다(최소 권한 관점에서는 오히려 바람직한 설계).

### 1-2. CodeDeploy 서비스 역할

- `codedeploy_role` (`CodeDeployServiceRole`) — CodeDeploy가 Blue/Green 배포 중 ASG 복제, ALB 타겟그룹 등록/해제, 리스너 수정 등을 대행하기 위해 assume하는 역할입니다. step5에서 분석한 `WITH_TRAFFIC_CONTROL` + `COPY_AUTO_SCALING_GROUP` 배포 방식이 실제로 동작하려면 이 역할의 권한이 필수적입니다.

### 1-3. 기타 서비스 역할

- 별도의 Lambda, ECS Task, CodePipeline/CodeBuild 서비스 역할은 존재하지 않습니다(step5에서 확인한 CI/CD 파이프라인 부재와 일치).

---

## 2. IAM 정책(Policy) 구성

### 2-1. 역할별 연결 정책 전체 목록

**`codedeploy_role`**
| 정책 | 유형 | 범위 |
|---|---|---|
| `AWSCodeDeployRole` | AWS 관리형 | CodeDeploy 실행 기본 권한 |
| `AWSCodeDeployFullAccess` | AWS 관리형 | CodeDeploy 콘솔/API 전체 제어 |
| `codedeploy_bluegreen_policy` | **고객 관리형(Customer Managed)** | EC2 Describe, ELB 등록/해제/리스너·타겟그룹 수정, **`autoscaling:*`(전체 와일드카드)**, `iam:PassRole`, `ec2:CreateTags`, `ec2:RunInstances` — `Resource = "*"` |

**`ec2_role` (WAS)**
| 정책 | 유형 | 범위 |
|---|---|---|
| `AmazonS3FullAccess` | AWS 관리형 | **계정 내 모든 S3 버킷**에 대한 전체 권한 |
| `AWSCodeDeployFullAccess` | AWS 관리형 | CodeDeploy 콘솔/API 전체 제어 (EC2 인스턴스 역할치고는 과도하게 넓음) |
| `AmazonEC2ContainerRegistryFullAccess` | AWS 관리형 | **계정 내 모든 ECR 리포지토리**에 대한 push/pull/삭제 등 전체 권한 |
| `ssm_parameter_read` | **고객 관리형** | `ssm:GetParameter(s/ByPath)`, `Resource = arn:...:parameter/spring/*`로 **정확히 스코프됨** |

**`ec2_s3_access` (DB EC2)**
| 정책 | 유형 | 범위 |
|---|---|---|
| `s3_access_policy` | **인라인(Inline, `aws_iam_role_policy`)** | `s3:ListBucket` on `arn:aws:s3:::koco-db-backup`, `s3:GetObject` on `koco-db-backup/*` — **버킷 단위로 정확히 스코프됨** |

**`monitoring_ec2_sd_role`**
| 정책 | 유형 | 범위 |
|---|---|---|
| `monitoring_ec2_sd_policy` | **고객 관리형** | `ec2:DescribeInstances`, `ec2:DescribeTags`만 허용, `Resource = "*"`(Describe류라 리소스 스코프 불가한 것이 정상) |

### 2-2. 인라인 정책 vs 관리형 정책 사용 방식

같은 "커스텀 정책"이라도 모듈마다 구현 방식이 다릅니다.

| 모듈 | 커스텀 정책 구현 방식 |
|---|---|
| `modules/iam` (codedeploy, ec2) | `aws_iam_policy` + `aws_iam_role_policy_attachment` — **고객 관리형 정책**(재사용/버전관리 가능, 콘솔의 "정책" 목록에 별도로 노출) |
| `modules/database-ec2` | `aws_iam_role_policy` — **순수 인라인 정책**(역할에 종속, 역할 삭제 시 함께 삭제, 별도 재사용 불가) |
| `modules/monitoring-ec2` | `aws_iam_policy` + `aws_iam_role_policy_attachment` — 고객 관리형 정책 |

- 기능적으로 유사한 목적(특정 역할 전용 권한 부여)인데도 **모듈별로 인라인/관리형 방식이 혼재**되어 있어 일관성이 부족합니다. 다만 DB 모듈처럼 재사용 필요가 없는 단일 용도라면 인라인 방식이 오히려 더 적절할 수도 있습니다.
- AWS 관리형 정책(`*FullAccess` 4종: S3, CodeDeploy, ECR + 2종 CodeDeploy 서비스용)에 크게 의존하고 있으며, 실제로 필요한 액션 대비 훨씬 넓은 권한을 부여하는 경향이 있습니다.

### 2-3. 최소 권한 원칙 적용 여부 — 역할별 평가

| 역할 | 평가 | 근거 |
|---|---|---|
| `ec2_s3_access` (DB EC2) | ✅ **우수** | 인라인 정책이 `koco-db-backup` 버킷 하나로 정확히 스코프 |
| `monitoring_ec2_sd_role` | ✅ **우수** | Describe류 읽기 전용 2개 액션만 허용 |
| `ssm_parameter_read` (ec2_role의 일부) | ✅ **우수** | `/spring/*` 경로로 정확히 스코프 |
| `codedeploy_bluegreen_policy` | ⚠️ **개선 필요** | 개별 액션을 나열해놓고 바로 뒤에 `"autoscaling:*"`(전체 와일드카드)를 추가해 앞의 세밀한 나열이 무의미해짐. `Resource = "*"`로 리소스 스코프도 없음. 주석("✅ 모든 Auto Scaling 권한 부여")으로 볼 때 의도적으로 넓게 열어둔 것으로 보이나, Blue/Green에 필요한 액션(`UpdateAutoScalingGroup`, `Describe*`, 라이프사이클 훅 관련)은 이미 명시되어 있으므로 `autoscaling:*` 와일드카드는 불필요하게 과도합니다. `ec2:RunInstances`, `iam:PassRole`도 `Resource = "*"`라 임의의 인스턴스 프로파일을 임의의 EC2에 붙일 수 있는 잠재적 권한 상승 경로가 될 수 있습니다. |
| `ec2_role` (WAS) | ⚠️ **개선 필요** | `AmazonS3FullAccess`(계정 전체 S3), `AmazonEC2ContainerRegistryFullAccess`(계정 전체 ECR), `AWSCodeDeployFullAccess`(콘솔 전체 제어) 3개의 AWS 관리형 `FullAccess` 정책을 EC2 인스턴스 역할에 그대로 부여 — 실제로 WAS EC2가 필요로 하는 동작(특정 ECR 리포지토리 pull, 특정 S3 버킷 접근, CodeDeploy Agent가 배포 상태를 보고하는 최소 API 호출)에 비해 훨씬 넓은 권한입니다. 이미 같은 역할 안에 `ssm_parameter_read`처럼 정교하게 스코프하는 패턴이 존재하므로, S3/ECR도 특정 리소스로 좁히는 것이 일관성 있는 개선 방향입니다. |
| `codedeploy_role`의 관리형 정책 2종 | ⚠️ **AWS 권장 패턴** | `AWSCodeDeployRole`은 AWS가 CodeDeploy 서비스 역할용으로 공식 권장하는 최소 정책이라 문제 없음. 다만 `AWSCodeDeployFullAccess`(콘솔 조작 권한까지 포함)를 서비스 역할에 추가로 붙인 것은 서비스 역할의 목적(배포 실행)을 넘어서는 권한입니다. |

**종합**: 순수 커스텀/인라인 정책(SSM, S3 백업 버킷, 모니터링 Describe)은 최소 권한이 잘 지켜진 반면, **AWS 관리형 `FullAccess` 정책에 의존하는 부분(WAS EC2, CodeDeploy 서비스 역할)에서 최소 권한 원칙이 상대적으로 느슨**합니다.

---

## 3. IAM 사용자/그룹 (있다면)

- 저장소 전체(`.tf` 파일 기준)를 검색한 결과 `aws_iam_user`, `aws_iam_group` 리소스는 **전혀 존재하지 않습니다.**
- 즉 이 IaC 저장소는 **서비스(EC2, CodeDeploy)가 assume하는 Role 기반 권한 체계만** 다루며, 사람이 콘솔/CLI에 로그인하는 IAM 사용자·그룹 관리는 범위 밖입니다.
- 관리자의 콘솔 접근은 IAM Identity Center(SSO), 별도 관리형 IAM 사용자, 혹은 루트 계정 등 **이 저장소 밖에서 별도로 관리되는 것으로 추정**되며, 코드만으로는 확인할 수 없습니다(step5에서 CI/CD 트리거 주체를 특정할 수 없었던 것과 같은 한계).

---

## 4. 전체 보안 설계 요약

### 4-1. Security Groups + IAM 조합으로 구성된 보안 레이어

이 프로젝트는 **네트워크 계층(SG)과 권한 계층(IAM)이 서로 다른 축을 담당**하는 이중 방어 구조입니다.

| 계층 | 통제 대상 | 담당 |
|---|---|---|
| Security Groups (step3) | "누가 이 서버에 **네트워크로 접근**할 수 있는가" | `alb_sg → app_sg → db_sg`, `openvpn_sg`가 관리 접근 허브 |
| IAM Role/Policy (본 문서) | "이 서버가 **AWS API로 무엇을 할 수 있는가**" | EC2 역할별로 S3/ECR/SSM/CodeDeploy 권한 분리 |

- 두 계층이 **역할별로 대응**됩니다: WAS EC2는 `app_sg`(네트워크) + `ec2_role`(권한), DB EC2는 `db_sg`(네트워크) + `ec2_s3_access`(권한), 모니터링 EC2는 자체 `monitoring_sg`(네트워크) + `monitoring_ec2_sd_role`(권한)으로 각각 짝을 이루며, 한 계층이 뚫리더라도 다른 계층이 추가 방어선이 되는 구조입니다.
- 다만 IAM 쪽에서 WAS EC2(`ec2_role`)가 `FullAccess`형 관리형 정책 3개를 보유하고 있어, 만약 SG를 우회해 WAS EC2가 침해당할 경우 **네트워크 통제와 무관하게 계정 전체 S3/ECR에 접근 가능**하다는 점은 SG의 세밀한 최소 권한 설계(app_sg/db_sg는 SG 참조만 사용)와 대비되는 약한 고리입니다.

### 4-2. 퍼블릭 노출 최소화 설계 여부

- **IAM 관점에서는 퍼블릭 노출 개념이 직접 적용되지 않지만**, "역할이 assume 가능한 주체"는 모두 `ec2.amazonaws.com` / `codedeploy.amazonaws.com`으로 제한되어 있어 외부 계정이나 익명 주체가 이 역할들을 탈취할 수 있는 신뢰 관계상의 허점은 없습니다.
- **대부분의 EC2에는 IMDSv2가 적용**되어 있습니다(WAS/DB/모니터링 EC2 모두 `metadata_options { http_tokens = "required" }`, step4에서 WAS EC2 확인, 이번 확인으로 DB/모니터링 EC2도 동일하게 적용됨을 확인). 다만 ⚠️ **`openvpn` 모듈만 예외**로, `modules/openvpn/main.tf`의 `metadata_options`가 `http_tokens = "optional"`로 설정되어 있어 IMDSv2가 강제되지 않습니다(자세한 내용은 5장 참고).
- 이 예외는 **가장 취약한 지점에서 발생**합니다: step3에서 확인한 대로 `openvpn_sg`는 5개 인그레스 규칙(1194/UDP, 22/TCP, 945/TCP, 443/TCP, 943/TCP)이 전부 `0.0.0.0/0`으로 개방되어 **프로젝트 내 가장 넓게 노출된 SG**인데, 정작 이 인스턴스의 메타데이터 보호 수준(IMDSv2 여부)은 프로젝트에서 가장 낮습니다. **노출도(네트워크 계층)와 방어 수준(메타데이터 계층)이 반비례하는 복합 리스크**이며, SSRF를 통한 자격증명 탈취 공격에는 이 인스턴스가 상대적으로 가장 취약합니다.
- 네트워크(SG) + IAM을 종합하면, DB/앱 서버는 "인터넷에서 직접 도달 불가 + IAM 신뢰 주체도 AWS 서비스로 한정"이라는 이중 조건으로 퍼블릭 노출이 잘 억제되어 있습니다. 유일한 예외는 `openvpn_sg`(step3)로, 네트워크 계층의 노출이 여전히 넓게 열려 있습니다.

### 4-3. 시크릿/환경변수 관리 방식

- **Spring 설정값**: `ec2_role`에 `/spring/*` 경로로 스코프된 SSM Parameter Store 읽기 전용 정책이 있어, WAS 애플리케이션 설정(DB 접속 정보 등 추정)을 SSM Parameter Store로 외부화하는 방식을 채택한 것으로 보입니다 — 이는 하드코딩을 피하는 올바른 패턴입니다.
- ⚠️ **중대 발견 — DB 루트 비밀번호 하드코딩**: `database-ec2` 모듈의 `db_server_user_data`(`dev.tfvars`, `prod.tfvars`, `dev_kubeadm/dev.tfvars` **3개 환경 모두 동일**, 221번째 줄 부근)에 다음과 같은 MySQL 초기화 스크립트가 포함되어 있습니다.

  ```
  ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'koco';
  ```

  - MySQL `root` 계정 비밀번호가 `'koco'`라는 **평문으로 Terraform 변수 파일에 하드코딩**되어 있고, 이 값이 **dev/prod 환경에서 동일**합니다.
  - `.tfvars` 파일이 git으로 버전관리되고 있다면(현재 git status상 두 파일 모두 수정/추적 대상), 이 비밀번호는 **저장소 히스토리에 영구적으로 남게** 됩니다.
  - 앞서 IAM에서 확인한 SSM Parameter Store 외부화 패턴(`/spring/*`)과 명백히 대비되는 사례로, **애플리케이션(Spring) 레벨 시크릿은 SSM으로 잘 외부화했지만, 인프라(DB 부트스트랩) 레벨 시크릿은 여전히 코드에 평문 하드코딩**되어 있어 프로젝트 내에서 시크릿 관리 수준이 계층마다 불균일합니다.
  - 개선 방향: DB 루트 비밀번호도 SSM SecureString 또는 Secrets Manager로 옮기고, `user_data`에서는 파라미터를 런타임에 조회하도록 변경하는 것이 바람직합니다.
- ⚠️ **동일 패턴의 2번째 사례 — OpenVPN 관리자 비밀번호 하드코딩**: 삭제된 `modules/openvpn/openvpn-setup.sh`(`git show HEAD:...`로 확인)에도 `ADMIN_PASSWORD="koco"`가 평문으로 하드코딩되어 있었으며, 이 값이 스크립트 내에서 로그로도 출력됩니다(`echo "Admin password: $ADMIN_PASSWORD"`).
  - **DB root 비밀번호와 완전히 동일한 값(`koco`)을 재사용**하는 취약 패턴이 이 저장소 안에서 최소 2곳(DB, OpenVPN)에 반복되어 있습니다.
  - 해당 파일은 현재 워킹트리에서는 삭제된 상태(`git status` 기준 `D`)이지만, **git 히스토리(HEAD 커밋)에는 여전히 남아있어** 자격증명 유출 리스크가 실질적으로 해소되지 않았습니다. 워킹 트리에서 파일을 지우는 것만으로는 과거 커밋을 통해 이 비밀번호가 계속 조회 가능하므로, `git filter-branch` 또는 BFG Repo Cleaner 등으로 **히스토리 자체를 정리**해야 합니다.
- AWS Access Key/Secret Key 등 자격증명 하드코딩은 발견되지 않았습니다(provider 인증은 별도 프로필/환경변수/OIDC 등을 사용하는 것으로 추정, 이 저장소 범위 밖).

### 4-4. IAM 리소스 네이밍과 환경 분리

- `codedeploy_role_name`, `ec2_role_name`, `monitoring_ec2_sd_role_name`, `ec2_s3_access_name` 등 **모든 IAM 리소스명은 각 환경의 루트 `main.tf`에서 `"${var.env}-${var.xxx_name}"` 형태로 접두사가 붙어** dev/prod가 서로 다른 실제 리소스명(`dev-CodeDeployServiceRole` vs `prod-CodeDeployServiceRole` 등)을 갖도록 되어 있습니다.
- 이는 step4에서 지적한 **ECR 리포지토리명(`app-repo`)이 dev/prod 간 접두사 없이 동일해 충돌 위험이 있었던 것과 대조적으로, IAM 모듈은 환경 분리가 일관되게 잘 적용된 부분**입니다.

---

## 5. OpenVPN 모듈 보안 분석 (신규 — 이전 step에서 미분석)

`modules/openvpn/`은 step1~5에서 모듈 목록·의존성 표에만 등장했을 뿐 코드가 직접 열람된 적이 없었습니다. 이번 보안 리뷰에서 직접 파일을 열어 아래 내용을 확인했습니다.

- **모듈 위치**: `modules/openvpn/` (`main.tf`, `variables.tf`, `outputs.tf` — outputs.tf는 비어 있음)

### 5-1. IMDSv2 미적용

```hcl
metadata_options {
  http_tokens   = "optional"
  http_endpoint = "enabled"
}
```
- WAS/DB/모니터링 EC2와 달리 `http_tokens = "optional"`로 설정되어 있어 IMDSv2가 강제되지 않습니다(4-2절 참고).

### 5-2. openvpn_sg — 프로젝트 내 최대 노출 SG

- step3에서 확인한 대로 `openvpn_sg`는 5개 인그레스 규칙(1194/UDP, 22/TCP, 945/TCP, 443/TCP, 943/TCP)이 전부 `0.0.0.0/0`으로 개방되어 있습니다.
- SSH(22)를 포함한 관리 포트 전체가 인터넷에 열려 있는 상태이며, 5-1의 IMDSv2 미적용과 결합하면 이 인스턴스는 프로젝트 내에서 네트워크 노출도와 메타데이터 방어 수준이 모두 가장 취약한 조합입니다.

### 5-3. 삭제된 openvpn-setup.sh — 하드코딩된 관리자 비밀번호

- `git show HEAD:Terraform_Project/modules/openvpn/openvpn-setup.sh`로 확인한 결과, `ADMIN_PASSWORD="koco"`가 평문으로 하드코딩되어 있었고 스크립트 내에서 로그로도 출력됩니다(`echo "Admin password: $ADMIN_PASSWORD"`).
- 현재 워킹트리에서는 파일이 삭제된 상태(`git status` 기준 `D`)이지만, **git 히스토리(HEAD 커밋)에는 여전히 남아 있어** 자격증명 유출 리스크가 해소되지 않았습니다. 히스토리 자체를 `git filter-branch` 또는 BFG Repo Cleaner로 정리할 필요가 있습니다.
- DB root 비밀번호(4-3절, `'koco'`)와 **동일한 값을 재사용**하고 있어, 이 프로젝트 전반에서 하나의 약한 비밀번호가 여러 시스템에 반복 사용되는 패턴이 확인됩니다.

### 5-4. 최근 리팩토링 이력

- `git diff` 확인 결과 최근 변경에서 `user_data = file("${path.module}/openvpn-setup.sh")`(주석 처리돼 있던 참조)가 완전히 제거되었고, 변수명도 `var.ami`→`var.openvpn_ami`, `var.key_name`→`var.openvpn_key_name` 등으로 리팩토링되었습니다. `openvpn-setup.sh` 파일 자체도 이 리팩토링 과정에서 함께 삭제된 것으로 보입니다.
- 다만 스크립트 삭제 및 `user_data` 참조 제거는 **워킹 트리 상태만 정리**했을 뿐 git 히스토리 정리로는 이어지지 않았으므로, 5-3의 자격증명 유출 리스크는 그대로 남아 있습니다.

---

## 요약

- **IAM 역할 분산 구조**: 공용 `iam` 모듈(CodeDeploy, WAS EC2) + `database-ec2`(DB 전용) + `monitoring-ec2`(모니터링 전용), 총 4개 역할이 3개 모듈에 나뉘어 존재. OpenVPN EC2만 인스턴스 프로파일 없음.
- **정책 구성**: DB/모니터링/SSM 관련 커스텀 정책은 매우 정교하게 스코프되어 최소 권한이 잘 지켜졌으나, WAS EC2 역할의 3종 AWS 관리형 `FullAccess`(S3/ECR/CodeDeploy)와 `codedeploy_bluegreen_policy`의 `autoscaling:*` 와일드카드는 필요 이상으로 넓은 권한.
- **인라인 vs 관리형**: 모듈별로 구현 방식이 혼재(iam/monitoring은 고객관리형, database-ec2는 순수 인라인) — 기능상 문제는 없으나 일관성 부족.
- **IAM 사용자/그룹**: 존재하지 않음 — 순수 서비스 Role 기반, 사람의 콘솔 접근 관리는 이 저장소 범위 밖.
- **SG + IAM 조합**: 서비스별로 네트워크(SG)-권한(IAM) 페어가 대응되는 이중 방어 구조이나, WAS EC2의 과도한 IAM 권한이 SG의 세밀한 최소 권한 설계를 상쇄할 수 있는 약한 고리.
- **퍼블릭 노출 최소화**: 대부분의 EC2(WAS/DB/모니터링)는 IMDSv2가 강제되어 있으나, ⚠️ **`openvpn` 모듈만 `http_tokens = "optional"`로 예외** — 하필 `openvpn_sg`(5개 규칙 전부 `0.0.0.0/0`)로 프로젝트 내 가장 넓게 노출된 인스턴스라 노출도와 방어 수준이 반비례하는 복합 리스크(5장 참고).
- **시크릿 관리**: Spring 앱 설정은 SSM Parameter Store(`/spring/*`)로 잘 외부화된 반면, ⚠️ **DB(MySQL) root 비밀번호(`'koco'`)가 dev/prod 모두 평문으로 tfvars에 하드코딩**되어 있는 중대한 보안 취약점 발견. 또한 삭제된 `openvpn-setup.sh`에도 **동일 값(`'koco'`)의 OpenVPN 관리자 비밀번호**가 하드코딩되어 있었고 git 히스토리에 잔존 — 동일 약한 비밀번호 재사용 패턴이 2곳에서 반복됨. 둘 다 최우선 개선 대상.
- **OpenVPN 모듈(5장, 신규 분석)**: 이전 step에서 미분석 상태였던 모듈로, IMDSv2 미적용·최대 노출 SG·하드코딩된 관리자 비밀번호(git 히스토리 잔존)까지 확인 — 프로젝트에서 가장 취약한 지점으로 재평가됨.
- **환경 분리**: IAM 리소스명은 전부 `${var.env}-` 접두사로 dev/prod가 명확히 분리되어 있어, 앞서 지적된 ECR 네이밍 이슈와 달리 이 영역은 잘 설계됨.
