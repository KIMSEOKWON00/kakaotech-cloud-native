# Step 7. S3 스토리지 & CDN(CloudFront) 구조 분석

작성일: 2026-07-04
대상: `Terraform_Project/modules/s3_static_site/*`, `modules/cdn/*`, `backend/main.tf`, `environments/{dev,prod,dev_kubeadm}/*.tfvars`

---

## 1. S3 버킷 구성

### 1-1. 버킷 목록 및 각 용도

이 프로젝트에는 목적이 다른 **2종류의 S3 버킷**이 존재합니다(둘 다 `modules/s3_static_site`가 아닌 서로 다른 위치에서 생성).

| 버킷 | 리소스 위치 | 용도 | 환경별 이름 |
|---|---|---|---|
| **프론트엔드 정적 호스팅** | `modules/s3_static_site/main.tf` (`aws_s3_bucket.frontend`) | SPA(정적 웹) 파일 호스팅, CloudFront 오리진 | dev: `dev-koco-front-s3`, prod: `prod-koco-front-s3` |
| **Terraform State** | `backend/main.tf` (`aws_s3_bucket.terraform_state`) | Terraform 원격 상태 저장 (dev/prod 공용, key로 구분) | `koco-terraformstate` (전 환경 공용 1개) |

- **배포 아티팩트 저장용 S3**는 이 두 모듈에 존재하지 않습니다. step5(배포파이프라인) 분석에서 IAM 역할(`ec2_role`)에 `AmazonS3FullAccess`가 부여된 것으로 미루어 CodeDeploy 배포 리비전을 S3에 저장할 가능성을 언급했으나, 그 버킷 자체를 생성하는 Terraform 리소스는 이 저장소에 없습니다(수동 생성되었거나 외부에서 관리되는 것으로 추정).
- **DB 백업용 S3**(`koco-db-backup`)는 `modules/database-ec2`(step6에서 분석)에서 참조되지만, 버킷 자체를 생성하는 코드는 없고 IAM 정책에서 ARN으로만 참조합니다 — 즉 이 버킷도 Terraform 관리 밖에서 이미 존재한다고 가정하고 있습니다.
- **로그 저장용 S3**(ALB 액세스 로그 등)는 존재하지 않으며, `prod.tfvars`/`dev.tfvars`에 `# alb_logs_bucket_name = (설정필요 테라폼으로 시도해봤는데 애러 발생함...)`라는 주석이 남아 있어 **ALB 로그 버킷 연동을 시도했으나 미완성 상태로 보류**된 것으로 확인됩니다. `Terraform-init/s3-buckets/koco-alb-logs/terraform.tfstate`를 직접 확인한 결과 `resources` 배열이 완전히 비어있음(0개)으로, 실제로 `apply`를 시도했으나 에러로 인해 버킷 생성 자체가 완료되지 않았다는 사실이 실증적으로 확인됩니다.
- **프론트엔드 빌드 백업용 S3**: `Terraform-init/s3-buckets/koco-frontend-backup/{dev,prod}`(`Terraform_Project`와 분리된 별도 로컬 state)에 버킷명 `dev-koco-frontend-backup`/`prod-koco-frontend-backup`으로 각각 생성되어 있습니다. `aws_s3_bucket_versioning`이 `Enabled`이고, `aws_s3_bucket_public_access_block`은 `block_public_acls`/`block_public_policy`/`ignore_public_acls`/`restrict_public_buckets` 4개 옵션이 전부 `true`로 퍼블릭 액세스가 완전 차단되어 있습니다. 프론트엔드 정적 호스팅 버킷(`{env}-koco-front-s3`)과는 **별개의 버킷**으로, 빌드 산출물 백업이 목적입니다.

### 1-2. 버킷 정책 및 접근 제어 설정

**프론트엔드 버킷** (`aws_s3_bucket_policy.frontend`)
```json
{
  "Sid": "AllowCloudFrontAccess",
  "Effect": "Allow",
  "Principal": { "AWS": "<cloudfront_oai_arn>" },
  "Action": "s3:GetObject",
  "Resource": "<bucket_arn>/*"
}
```
- **CloudFront OAI(Origin Access Identity)의 IAM ARN만** `Principal`로 허용하고, 그 외 어떤 주체(퍼블릭, 다른 계정 등)도 버킷 객체에 접근할 수 없습니다.
- 정책 적용 전에 `aws_s3_bucket_public_access_block`이 먼저 적용되도록 `depends_on`으로 순서를 명시해, 퍼블릭 정책이 실수로 열리는 것을 방지하는 순서 안전장치가 되어 있습니다.

**Terraform State 버킷** — 별도의 `aws_s3_bucket_policy`는 없고, `aws_s3_bucket_public_access_block`으로만 퍼블릭 접근을 차단합니다. State 파일 자체에 대한 세밀한 IAM 정책(특정 역할만 읽기/쓰기 허용 등)은 이 파일에 정의되어 있지 않으며, 계정 내 IAM 사용자/역할의 기본 권한에 의존하는 구조입니다.

### 1-3. 버저닝 / 암호화 설정

| 버킷 | 버저닝 | 서버 측 암호화(SSE) |
|---|---|---|
| **Terraform State** (`backend/main.tf`) | ✅ `aws_s3_bucket_versioning` `Enabled` | ✅ `aws_s3_bucket_server_side_encryption_configuration` (`AES256`) |
| **프론트엔드 정적 호스팅** (`s3_static_site`) | ❌ 설정 없음 | ❌ 설정 없음 |

- ⚠️ **State 버킷은 버저닝+암호화가 모두 적용되어 모범적으로 구성**된 반면, **프론트엔드 버킷은 버저닝과 암호화 설정이 전혀 없습니다.**
  - 버저닝 부재: 배포 실수로 정적 파일을 덮어쓰거나 삭제해도 이전 버전으로 롤백할 수 없습니다.
  - 암호화 부재: S3 기본값은 SSE-S3가 자동 적용되는 리전도 있으나(2023년 이후 AWS는 기본 암호화를 디폴트로 전환했음), Terraform 코드 수준에서 명시적으로 강제하고 있지는 않아 코드만으로는 암호화가 "보장"된다고 보기 어렵습니다.
  - 정적 파일(HTML/JS/CSS)은 민감도가 낮아 암호화 우선순위가 낮을 수 있으나, 버저닝 부재는 운영 안정성 측면에서 개선 여지가 있습니다.
- `main.tf`에 `force_destroy`와 `lifecycle { prevent_destroy }`가 **주석 처리되어 있어(코드상 비활성)**, 현재는 `terraform destroy` 시 버킷이 비어있지 않아도 상황에 따라 삭제될 수 있는 상태입니다(실수 방지 장치가 꺼져 있음).

### 1-4. 퍼블릭 액세스 차단 설정

- 두 버킷 모두 `aws_s3_bucket_public_access_block`이 4개 옵션(`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`) 전부 `true`로 설정되어 있어 **퍼블릭 액세스가 완전히 차단**되어 있습니다.
- 프론트엔드 정적 파일임에도 S3 자체는 완전 비공개로 잠그고, CloudFront(OAI)를 통해서만 접근을 허용하는 것이 이 프로젝트의 핵심 설계입니다(아래 2, 3장에서 상술).

---

## 2. CDN (CloudFront) 구성

### 2-1. 오리진 설정

`aws_cloudfront_distribution.cdn`은 **2개의 오리진**을 가진 단일 배포로, 정적 프론트엔드와 백엔드 API를 하나의 도메인에서 함께 서빙합니다.

| 오리진 ID | 대상 | 연결 방식 |
|---|---|---|
| `S3-<bucket_name>` | 프론트엔드 S3 버킷 (`<bucket>.s3.<region>.amazonaws.com`) | `s3_origin_config` + OAI |
| `ALB-Spring` | ALB(`var.alb_dns_name`) | `custom_origin_config` (`origin_protocol_policy = "https-only"`, `origin_ssl_protocols = ["TLSv1.2"]`) |

- ⚠️ **코드 내 주석으로 표기된 미해결 이슈**: `origin { domain_name = var.alb_dns_name ... }` 라인에 `# alb dns 이름이 아니라 api.koco.click 또는 api.ktbkoco.com 으로 설정해야 함`이라는 주석이 남아 있습니다. 즉 현재는 ALB의 원시 DNS 이름을 오리진으로 쓰고 있지만, 실제로는 ALB 모듈(step4)에서 만든 Route53 alias 레코드(`api.<domain>`)를 오리진으로 써야 한다는 것을 작성자 스스로 인지하고 있는 **미완료/알려진 개선 항목**입니다. ALB DNS 이름을 직접 쓰면 ALB가 재생성되어 DNS 이름이 바뀔 경우 CDN 오리진이 끊어질 수 있어, 안정적인 커스텀 도메인(alias)을 쓰는 것이 더 견고합니다.

### 2-2. 캐싱 정책 설정

`ordered_cache_behavior` 3개 + `default_cache_behavior` 1개로 경로 기반 라우팅/캐싱을 구성합니다.

| 경로 패턴 | 대상 오리진 | 캐시 TTL(min/default/max) | 쿼리스트링 | 쿠키 | 비고 |
|---|---|---|---|---|---|
| `/oauth/*` | ALB-Spring | 0/0/0 (**캐시 안 함**) | 전달 | 전체 전달 | OAuth 인증 흐름 — 캐시되면 안 되는 요청 |
| `/api/*` | ALB-Spring | 0/0/0 (**캐시 안 함**) | 전달 | 전체 전달 | Spring Boot API 요청 |
| `/game/*` | S3(정적) | 0/3600/86400 | 미전달 | 미전달 | Unity WebGL 게임 리소스 — 1시간 기본 캐시 |
| *(기본)* | S3(정적) | 0/3600/86400 | 미전달 | 미전달 | 일반 SPA 정적 파일 |

- `/oauth/*`, `/api/*`는 `min/default/max_ttl = 0`으로 **사실상 캐싱을 비활성화**하고 매 요청을 오리진(ALB)까지 전달 — 동적 API 응답을 캐시하지 않는 올바른 설계입니다. 또한 `headers = ["Authorization"]`을 전달해 인증 토큰이 필요한 API 호출이 정상 동작하도록 배려되어 있습니다.
- 정적 자원(기본/`/game/*`)은 `default_ttl=3600`(1시간)/`max_ttl=86400`(1일)로 적당한 수준의 캐싱을 적용해 CDN의 성능 이점을 살리고 있습니다.
- **`forwarded_values`(Legacy 캐시 정책 방식) 사용**: CloudFront의 최신 권장 방식인 `cache_policy_id`/`origin_request_policy_id`(Cache Policy/Origin Request Policy 객체) 대신, 구버전 API인 `forwarded_values` 블록을 그대로 사용하고 있습니다. 기능적으로는 동작하지만 AWS가 신규 배포에 권장하는 방식은 아닙니다.
- **SPA 라우팅 지원**: `custom_error_response`로 403/404 오류를 200 + `index.html`로 리다이렉트 처리해, 클라이언트 사이드 라우팅(React Router 등)이 새로고침 시에도 깨지지 않도록 구성되어 있습니다.

### 2-3. 지리적 제한 설정

- `restrictions { geo_restriction { restriction_type = "none" } }` — **지리적 제한이 전혀 설정되어 있지 않습니다.** 전 세계 모든 국가에서 접근 가능합니다.

### 2-4. HTTPS 강제 설정

- 4개 캐시 동작(`default_cache_behavior` + 3개 `ordered_cache_behavior`) 전부 `viewer_protocol_policy = "redirect-to-https"`로, HTTP로 접속해도 HTTPS로 강제 리다이렉트됩니다.
- `viewer_certificate`에 환경별 ACM 인증서(`var.acm_certificate_arn`, **`us-east-1` 리전** — CloudFront 요구사항에 맞게 정확히 구성됨, step2/step4에서도 확인된 패턴)를 사용하고, `ssl_support_method = "sni-only"`, `minimum_protocol_version = "TLSv1.2_2021"`로 **최신 TLS 정책이 적용**되어 있습니다(ALB의 `ELBSecurityPolicy-2016-08`보다 CDN 쪽 TLS 정책이 더 최신입니다 — step4 대비 개선된 점).
- **WAF 연동**: `web_acl_id = var.waf_web_acl_id`로 환경별 WAF WebACL(`secure-waf-dev`/`secure-waf-prod`, `us-east-1` 글로벌 — CloudFront용 WAF 요구사항에 맞게 올바른 리전)이 연결되어 있습니다. WAF 실제 생성 코드는 `Terraform_Project`가 아니라 **`Terraform-init/waf/` 폴더에서 별도(로컬 state)로 관리**되며, 4개 규칙 중 실제로 유효한 규칙과 사실상 미작동인 규칙이 섞여 있습니다.
  - **[실제 차단 활성]**
    - Rate-limit(`rate-limit-{env}`): IP당 5분/1000회 초과 시 차단.
    - AWS 관리형룰(`aws-managed-threats-{env}`, `AWSManagedRulesCommonRuleSet`): `override_action = none`으로 설정되어 있어 룰그룹 내부의 원래 block 액션(SQL Injection/XSS 등)을 그대로 사용 → **실제 차단이 활성화된 상태**입니다. (코드 주석 "초기에는 none{}으로 로그만 보고..."는 `count{}`를 선택했을 경우에 대한 설명이며, 실제 설정된 `none{}`의 동작 설명이 아닙니다 — 주석과 실제 동작이 어긋나 있습니다.)
  - **[사실상 미작동]**
    - 수동 IP 차단(`block-bad-ips-{env}`, `blocked_ips` IP Set): 현재 `addresses`가 빈 리스트(주석만 있고 실제 IP 없음)라 실질적인 차단 효과가 없습니다.
    - GeoMatch(`allow-korea-{env}`): `default_action = allow` 구조에서 이 규칙은 KR 트래픽에 `action { allow {} }`만 부여할 뿐 `block` 액션이 없어, 비한국 트래픽도 다른 규칙에 걸리지 않으면 그대로 default_action(allow)을 통과합니다 — **규칙명과 달리 실제로는 지리적 제한 효과가 없는 사실상 no-op 규칙**입니다.
  - 이는 ALB 자체에는 없는(step4에서 미확인) 추가 보안 계층이지만, 위와 같이 일부 규칙은 아직 실효성이 없어 "1차 방어선"이 부분적으로만 작동하는 상태로 평가해야 합니다.

### 2-5. OAC / OAI 설정 (S3 직접 접근 차단)

- `aws_cloudfront_origin_access_identity.frontend_oai`를 사용하는 **OAI(Origin Access Identity, 구세대 방식) 방식**이 적용되어 있습니다. AWS가 최근 권장하는 **OAC(Origin Access Control)는 사용되지 않았습니다.**
  - OAI는 2022년 이후 AWS가 신규 배포에는 OAC로 전환할 것을 권장하는 레거시 메커니즘이지만, 여전히 지원되며 기능적으로는 정상 동작합니다.
  - S3 버킷 정책이 이 OAI의 IAM ARN만 허용하도록 되어 있어(1-2절 참고), **S3 URL로 직접 접근 시 403이 반환**되고 반드시 CloudFront를 경유해야만 정적 파일에 접근할 수 있는 구조가 올바르게 구현되어 있습니다.

---

## 3. S3 + CloudFront 연동 구조

### 3-1. 정적 자원 제공 흐름

```
사용자 브라우저
     │ https://koco.click (또는 www.koco.click)
     ▼
Route53 (aws_route53_record.cdn_root / cdn_www, A-alias)
     ▼
CloudFront (aws_cloudfront_distribution.cdn)
     │
     ├─ 경로가 /oauth/*, /api/* ──────────▶ ALB-Spring 오리진 (캐시 안 함, Authorization 헤더 전달)
     │                                         └─▶ ALB → ASG(EC2, WAS) [step4 참고]
     │
     └─ 그 외 경로(/game/*, 기본) ─────────▶ S3-<bucket> 오리진 (OAI 경유)
                                               └─▶ S3 버킷 정책이 OAI만 허용, 퍼블릭 직접 접근 차단
```

- 프론트엔드 모듈(`s3_static_site`)은 `cloudfront_oai_arn`을 CDN 모듈의 출력값(`module.cdn.cloudfront_oai_arn`)으로 주입받고, CDN 모듈은 `s3_bucket_name`을 변수로 받아 오리진 도메인을 구성 — **두 모듈이 서로의 출력을 참조하는 순환적 의존 관계**입니다. Terraform 자체는 리소스 그래프로 이를 처리하지만(OAI를 먼저 만들고 그 ARN을 S3 정책에 반영), 모듈 간 결합도가 높은 설계입니다.
- API 트래픽(`/oauth/*`, `/api/*`)과 정적 자원 트래픽이 **동일한 도메인(`koco.click`/`ktbkoco.com`)의 다른 경로**로 라우팅되어, 프론트엔드에서 CORS 설정 없이 동일 출처(same-origin)로 API를 호출할 수 있는 구조입니다 — 이는 CDN 도입의 실질적인 이점 중 하나입니다.

### 3-2. 캐시 무효화 전략

- 코드베이스 전체(`.tf` 파일 및 인프라 스크립트)에 `aws_cloudfront_invalidation`에 해당하는 Terraform 리소스는 없으며(CloudFront invalidation은 Terraform 리소스로 직접 관리되지 않는 것이 일반적), 배포 파이프라인 스크립트(`aws cloudfront create-invalidation` CLI 호출 등)도 저장소 내에서 발견되지 않았습니다.
- step5(배포파이프라인) 분석에서 이미 확인했듯 이 저장소에는 CI/CD 파이프라인 자체가 없으므로, **프론트엔드 배포 후 캐시 무효화가 자동화되어 있는지 여부는 이 저장소만으로는 확인할 수 없습니다.** 정적 파일 배포와 무효화는 별도의 외부 프로세스(수동 CLI, 별도 프론트엔드 배포 저장소의 CI 등)에서 처리되는 것으로 추정됩니다.
- 대안적으로 `default_ttl=3600`(1시간)이라는 비교적 짧은 캐시 수명을 둔 것은, 명시적 무효화가 없어도 배포 후 최대 1시간 내에는 새 버전이 자동 반영되도록 하는 완충 장치로 볼 수 있습니다.

---

## 4. 설계 의도 분석

### 4-1. CDN 도입으로 기대한 효과

- **정적 자원의 엣지 캐싱**: 전 세계(지리적 제한 없음) 사용자에게 CloudFront 엣지 로케이션을 통해 정적 SPA 파일을 짧은 지연시간으로 제공하려는 의도가 명확합니다.
- **API와 정적 자원의 단일 도메인 통합**: ALB를 별도 오리진으로 등록해 `/api/*`, `/oauth/*`는 캐시 없이 그대로 통과시키면서도, 사용자 입장에서는 하나의 도메인(`koco.click`)만으로 프론트+백엔드를 모두 이용하게 하는 아키텍처 — 별도의 API 서브도메인을 쓰는 것보다 CORS 이슈를 원천 차단할 수 있는 실용적 선택입니다(다만 ALB 모듈은 `api.<domain>` 서브도메인으로도 별도 접근 가능하도록 되어 있어, 두 경로가 공존하는 것으로 보입니다).
- **S3 프라이빗화 + WAF**: S3를 완전 비공개로 걸어 잠그고 CloudFront(OAI)만 접근을 허용함으로써 정적 콘텐츠에 대한 직접 노출을 차단하고, WAF를 CDN 레벨에 연결해 CDN을 "엣지에서의 보안 검문소" 역할까지 겸하게 하려는 의도가 엿보입니다.
- **Unity WebGL 게임 라우팅**(`/game/*`)이 별도 캐시 동작으로 존재하는 것으로 보아, 이 서비스는 단순 웹앱이 아니라 **웹 기반 게임 콘텐츠 배포까지 포함하는 서비스**로 추정됩니다(step1/2에서 다루지 않은 새로운 서비스 성격 단서).

### 4-2. 비용/성능 최적화 고려 여부

- **성능**: 정적 파일에 대해 최대 1일(`86400`초) 캐시를 허용해 오리진(S3) 요청 횟수를 줄이고, API 트래픽만 선택적으로 캐시를 우회시켜 "캐시 가능한 것은 최대한 캐시, 캐시 불가능한 것은 즉시 통과"라는 원칙이 잘 반영되어 있습니다.
- **비용**: `AllowCloudFrontAccess` 정책 + `s3_origin_config`(OAI) 조합은 S3 데이터 전송 비용을 CloudFront 캐시 히트 비율만큼 절감하는 전형적인 패턴입니다. 다만:
  - 프론트엔드 버킷에 **버저닝이 없어** 이전 배포 버전이 자동 보존되지 않으므로(1-3절), 버전 보존에 따른 추가 스토리지 비용은 발생하지 않는 대신 롤백 능력을 희생한 트레이드오프로 보입니다.
  - ALB 로그 버킷 연동이 주석 처리된 채 미완료 상태(`# alb_logs_bucket_name = (설정필요 ...)`)로 남아 있어, 액세스 로그 기반 비용/트래픽 분석은 현재 인프라만으로는 불가능합니다.
- **개선 여지**: `forwarded_values`(레거시) 대신 CloudFront Cache Policy/Origin Request Policy로 전환하면 캐시 키를 더 세밀하게 제어해 캐시 히트율을 높이고 오리진 요청을 추가로 줄일 수 있습니다. 또한 OAI → OAC 전환은 비용에는 영향이 적지만 AWS의 최신 보안 권장사항에 부합합니다.

### 4-3. 환경 간 리소스 네이밍 — dev_kubeadm과의 충돌 위험

- `environments/dev_kubeadm/dev.tfvars`도 `s3_static_site`/`cdn` 모듈을 사용하며, `bucket_name = "dev-koco-front-s3"`, `domain_name = "koco.click"`로 **`dev` 환경과 완전히 동일한 값**을 사용합니다.
- S3 버킷명은 리전 내 전역 유일해야 하고, Route53 레코드(`koco.click`, `www.koco.click`)와 CloudFront `aliases`도 동일 도메인을 가리키므로, **`dev`와 `dev_kubeadm`을 동시에 `apply`하면 버킷 생성 충돌 또는 동일 도메인에 대한 CloudFront alias 중복 문제가 발생**할 수 있습니다.
- step4에서 지적한 ECR 리포지토리명 충돌(dev/prod `app-repo`)과 유사한 패턴의 위험으로, **`dev`와 `dev_kubeadm`은 상호 배타적으로 운영(하나만 활성 상태로 유지)되어야 하는 실험적 대체 환경**임을 시사합니다.

---

## 요약

- **S3 버킷**: 프론트엔드 정적 호스팅용(`{env}-koco-front-s3`)과 Terraform State용(`koco-terraformstate`) 2종. 배포 아티팩트/DB 백업/로그 버킷은 이 저장소에서 직접 생성되지 않고 외부 존재를 가정.
- **접근 제어**: 두 버킷 모두 퍼블릭 액세스 완전 차단, 프론트엔드 버킷은 CloudFront OAI만 허용하는 버킷 정책으로 S3 직접 접근을 차단.
- **버저닝/암호화**: State 버킷은 버저닝+AES256 암호화 모두 적용(모범적), ⚠️ **프론트엔드 버킷은 버저닝·암호화 설정이 전혀 없음** — 개선 여지.
- **CDN 구성**: S3(정적)+ALB(API) 이중 오리진, `/api/*`·`/oauth/*`는 캐시 비활성화로 오리진 직결, 나머지는 최대 1일 캐시. HTTPS 강제, `TLSv1.2_2021`, WAF(WebACL) 연동까지 CDN 레벨 보안이 잘 구성됨.
- **알려진 미해결 이슈(코드 주석 근거)**: ALB 오리진이 원시 DNS 이름을 사용 중이며 커스텀 도메인으로 교체 필요하다는 작성자 본인의 주석이 남아 있음. ALB 로그 버킷 연동도 에러로 인해 미완료 상태.
- **레거시 방식 사용**: OAI(OAC 아님), `forwarded_values`(Cache Policy 객체 아님) — 동작은 하지만 AWS 최신 권장 방식은 아님.
- **캐시 무효화**: Terraform/저장소 내 자동화된 무효화 전략 없음 — CI/CD 부재(step5)와 마찬가지로 외부 프로세스에 의존하는 것으로 추정, 짧은 TTL(1시간)이 완충 역할.
- **환경 충돌 위험**: `dev_kubeadm`이 `dev`와 동일한 S3 버킷명/도메인을 사용해 동시 운영 시 충돌 가능 — ECR 네이밍 이슈(step4)와 유사한 패턴.

---

## Terraform-init 부가 리소스

`Terraform_Project`와 백엔드/state가 완전히 분리된 별도 저장소입니다. 로컬 state로만 관리되며 `Terraform_Project`와 상호 참조(원격 state 참조 등) 없이 독립적으로 존재합니다.

| 리소스 | 환경 | 상태 | 비고 |
|---|---|---|---|
| `koco-alb-logs` | 단일 | 생성 실패 (빈 state) | ALB 로그 버킷 |
| `koco-codedeploy-artifacts` | dev/prod | 생성 완료 | CodeDeploy 아티팩트 |
| `koco-frontend-backup` | dev/prod | 생성 완료 | 프론트엔드 빌드 백업 |
| WAF (`dev_waf`/`prod_waf`) | dev/prod | 생성 완료 | CloudFront 연동 WAF |
