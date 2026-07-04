# Step 3. 네트워크(VPC) & Security Groups 구조 분석

작성일: 2026-07-04
대상: `Terraform_Project/modules/network/*`, `Terraform_Project/modules/security_groups/*`, `Terraform_Project/modules/monitoring-ec2/main.tf`(SG 부분), `environments/{dev,prod,dev_kubeadm}/*.tfvars`

---

## 1. VPC 구성

### 1-1. CIDR 블록 설계

| 환경 | VPC CIDR | 비고 |
|---|---|---|
| dev | `10.1.0.0/16` | 2번째 옥텟(`.1.`)으로 환경 구분 |
| prod | `10.3.0.0/16` | 2번째 옥텟(`.3.`)으로 환경 구분 |

- `vpc_cidr`은 모듈 변수(`variable "vpc_cidr"`)로 받아 `aws_vpc.main`에 그대로 주입되며, `enable_dns_support = true`, `enable_dns_hostnames = true`가 고정 설정되어 있어 프라이빗 DNS 해석(내부 도메인, VPC 엔드포인트 등)이 항상 가능하도록 되어 있습니다.
- dev(`10.1.0.0/16`)와 prod(`10.3.0.0/16`) 사이에 `10.2.0.0/16`(2번째 옥텟 `.2.`)이 비어 있으나, **`environments/dev_kubeadm/dev.tfvars`를 직접 확인한 결과 실제 `vpc_cidr`은 `10.1.0.0/16`으로 dev와 완전히 동일**합니다(정정: 이전 버전에서 "10.2.0.0/16이 dev_kubeadm 예약 대역"으로 추정했던 내용은 오류였음). 별도 VPC 리소스이므로 CIDR 자체가 충돌하지는 않지만, step7에서 발견한 S3 버킷명·도메인 공유 문제와 같은 선상에서 **"`dev_kubeadm` = `dev`의 미완성 복제본"이라는 패턴이 네트워크 계층(VPC CIDR)에서도 동일하게 확인**됩니다.
- `/16`(65,536개 IP)을 VPC 전체에 할당하고 서브넷은 `/24`(256개 IP) 단위로 쪼개는, 여유 있는 주소 설계입니다.

### 1-2. 가용 영역(AZ) 구성

- 사용 AZ: `ap-northeast-2a`, `ap-northeast-2c` (2개 AZ, dev/prod 동일)
- 퍼블릭/프라이빗-앱/프라이빗-DB 서브넷 모두 **정확히 2a, 2c 조합으로 1개씩** 생성되어, 모든 계층이 2-AZ 이중화 구조를 갖습니다.

### 1-3. 퍼블릭 / 프라이빗 서브넷 분리 구조

`network` 모듈은 3개 계층의 서브넷을 생성합니다.

| 서브넷 종류 | 리소스 | 개수(AZ) | `map_public_ip_on_launch` | 용도 |
|---|---|---|---|---|
| 퍼블릭 | `aws_subnet.public` | 2 (2a, 2c) | `true` | ALB, NAT Gateway, OpenVPN 등 외부 접점 |
| 프라이빗-앱 | `aws_subnet.private_app` | 2 (2a, 2c) | `false` | ASG/EC2(WAS), 모니터링 서버 |
| 프라이빗-DB | `aws_subnet.private_db` | 2 (2a, 2c) | `false` | DB용 EC2(MySQL) |

- 퍼블릭 서브넷만 `map_public_ip_on_launch = true`로 자동 공인 IP를 부여하고, 나머지 두 프라이빗 계층은 `false`로 외부에서 직접 접근이 불가능하도록 구성되어 있습니다.
- 앱 계층과 DB 계층을 같은 "프라이빗"이라도 별도 서브넷(및 별도 라우트 테이블)으로 완전히 분리하여, 3-tier(퍼블릭 – 프라이빗 앱 – 프라이빗 DB) 구조를 명확히 구현하고 있습니다.

### 1-4. 서브넷 CIDR 설계 방식

`variable "public_subnets"`, `private_app_subnets`, `private_db_subnets`는 모두 `list(object({ cidr = string, az = string }))` 타입으로, tfvars에서 `{cidr, az}` 쌍의 리스트를 직접 명시하는 방식입니다(모듈 내부에서 `cidrsubnet()` 등으로 자동 계산하지 않고 값 자체를 하드코딩해서 주입).

dev 기준 서브넷 배치:

```
10.1.0.0/16 (VPC)
├── 10.1.1.0/24  Public      (ap-northeast-2a)
├── 10.1.2.0/24  Public      (ap-northeast-2c)
├── 10.1.3.0/24  Private-APP (ap-northeast-2a)
├── 10.1.4.0/24  Private-DB  (ap-northeast-2a)
├── 10.1.5.0/24  Private-APP (ap-northeast-2c)
└── 10.1.6.0/24  Private-DB  (ap-northeast-2c)
```

prod는 `10.3.x.0/24`로 동일한 옥텟 순서(1=Public-2a, 2=Public-2c, 3=APP-2a, 4=DB-2a, 5=APP-2c, 6=DB-2c) 패턴을 그대로 반복합니다.

- **설계 방식 특징**: 3번째 옥텟을 1씩 증가시키며 "Public(1,2) → APP(3) → DB(4) → APP(5) → DB(6)"의 다소 교차된 순서로 배치되어 있어, "Public 2개 → APP 2개 → DB 2개"처럼 계층별로 연속 배치되는 일반적인 패턴과는 약간 다릅니다. AZ별로 보면 `2a`는 (1,3,4), `2c`는 (2,5,6)이 할당되어 있습니다.
- 서브넷 CIDR이 `.tfvars`에 고정 문자열로 박혀 있어, AZ나 서브넷을 추가하려면 코드(리스트 항목) 추가와 CIDR 값 수동 계산이 필요합니다(자동 확장 로직 없음).

---

## 2. 라우팅 구성

### 2-1. 인터넷 게이트웨이 (IGW)

- `aws_internet_gateway.igw` 1개를 VPC당 생성, 퍼블릭 라우트 테이블(`public_rt`)의 `0.0.0.0/0` 경로로 연결됩니다.

### 2-2. NAT 게이트웨이 구성

- `aws_nat_gateway.nat` **1개만 생성**되며, `subnet_id = aws_subnet.public[0].id`로 **첫 번째 퍼블릭 서브넷(2a)에 고정**되어 있습니다.
- NAT용 EIP(`aws_eip.nat`)도 1개만 생성됩니다.
- 프라이빗-앱, 프라이빗-DB 라우트 테이블은 AZ(2a/2c)별로 각각 만들어지지만(`count = length(var.private_app_subnets)` 등), 모두 **동일한 단일 NAT 게이트웨이**(`aws_nat_gateway.nat.id`, count 없음)를 가리킵니다.
- ⚠️ **가용성 관찰**: NAT가 단일 AZ(2a)에만 존재하므로, 2a 가용영역 장애 시 2c의 프라이빗 서브넷들도 아웃바운드 인터넷 통신이 불가능해질 수 있습니다. 서브넷/라우트 테이블 자체는 AZ별로 분리되어 있지만 NAT 계층에서는 단일 장애점(SPOF)이 존재합니다.

### 2-3. 라우팅 테이블 설계

| 라우트 테이블 | 개수 | 목적지 | 대상 |
|---|---|---|---|
| `public_rt` | 1개 (공용) | `0.0.0.0/0` | `aws_internet_gateway.igw` |
| `private_app_rt` | AZ당 1개(2개) | `0.0.0.0/0` | 단일 `aws_nat_gateway.nat` |
| `private_db_rt` | AZ당 1개(2개) | `0.0.0.0/0` | 단일 `aws_nat_gateway.nat` |

- 퍼블릭 라우트 테이블은 1개를 만들어 두 퍼블릭 서브넷이 공유(`aws_route_table_association.public_assoc`, count 기반)합니다.
- 프라이빗 앱/DB는 AZ별로 별도 라우트 테이블을 만들지만(관리 단위는 AZ별로 분리), 실제 라우팅 대상(NAT)은 앞서 언급한 대로 동일 NAT 하나를 공유합니다. AZ별로 라우트 테이블을 분리해 둔 것은 향후 AZ별 NAT를 추가할 때 확장하기 쉬운 구조이나, 현재는 그 이점을 활용하지 않고 있습니다.
- 모든 라우트 테이블이 `0.0.0.0/0` 아웃바운드만 정의하며, DB 서브넷에서 별도의 축소된 라우팅(예: NAT 미경유, VPC 내부 통신만 허용)은 적용되어 있지 않습니다 — DB 서브넷도 앱 서브넷과 동일하게 NAT를 통한 아웃바운드 인터넷 접근이 가능합니다(실제 인바운드 통제는 후술할 Security Group에서 담당).

---

## 3. Security Groups 구성

### 3-1. 정의된 보안 그룹 목록 및 용도

`security_groups` 모듈은 입력값으로 `vpc_id` 하나만 받아(`module.network.vpc_id`), 4개의 보안 그룹을 생성합니다. 여기에 더해 `monitoring-ec2` 모듈이 공용 `security_groups` 모듈과는 별도로 자체 보안 그룹(`monitoring_sg`)을 하나 더 정의하고 있어, **저장소 전체 기준으로는 SG가 총 5개**입니다. 아래는 두 모듈에 흩어져 있는 SG를 하나의 표로 통합 정리한 것입니다.

| SG | 리소스명 | 정의 위치 | 용도 |
|---|---|---|---|
| `openvpn_sg` | `openvpn-sg` | `modules/security_groups` | OpenVPN 서버(관리자 원격 접속용) |
| `alb_sg` | `alb-sg` | `modules/security_groups` | ALB(외부 트래픽 진입점) |
| `app_sg` | `app-sg` | `modules/security_groups` | 애플리케이션(WAS) 서버 — ALB에서만 트래픽 허용 |
| `db_sg` | `db_sg` | `modules/security_groups` | DB(MySQL) 서버 — APP/OpenVPN에서만 트래픽 허용 |
| `monitoring_sg` | `monitoring-sg` | `modules/monitoring-ec2` (공용 모듈 밖, 자체 정의) | 모니터링 서버(Prometheus/Scouter) 전용 SG |

### 3-2. 인바운드/아웃바운드 규칙 상세

**`openvpn_sg`**
| 방향 | 포트 | 프로토콜 | 소스 | 비고 |
|---|---|---|---|---|
| in | 1194 | UDP | `0.0.0.0/0` | OpenVPN 터널링 트래픽 |
| in | 22 | TCP | `0.0.0.0/0` | SSH |
| in | 945 | TCP | `0.0.0.0/0` | (OpenVPN 관련 부가 포트로 추정) |
| in | 443 | TCP | `0.0.0.0/0` | HTTPS(관리 웹 UI 등) |
| in | 943 | TCP | `0.0.0.0/0` | OpenVPN Admin Web UI |
| out | 전체 | 전체(`-1`) | `0.0.0.0/0` | 전체 허용 |

⚠️ SSH(22)를 포함한 모든 인바운드 규칙이 `0.0.0.0/0`(전 인터넷)에 열려 있어, OpenVPN이 인터넷에서 직접 노출되는 관리 서버임을 감안해도 최소 권한 원칙 관점에서는 다소 느슨합니다(특히 22, 945, 443, 943 포트).

**`alb_sg`**
| 방향 | 포트 | 프로토콜 | 소스 |
|---|---|---|---|
| in | 80 | TCP | `0.0.0.0/0` |
| in | 443 | TCP | `0.0.0.0/0` |
| in | 8080 | TCP | `0.0.0.0/0` |
| out | 전체 | 전체 | `0.0.0.0/0` |

- 퍼블릭 로드밸런서이므로 80/443을 전체 공개하는 것은 합리적입니다.다만 `8080`까지 `0.0.0.0/0`으로 열려 있는 점은 (일반적으로 8080은 ALB→APP 구간에서만 쓰이는 내부 포트인 경우가 많아) 외부에 노출할 필요가 있는지 검토가 필요합니다.

**`app_sg`** (SG 참조 방식만 사용, CIDR 없음)
| 방향 | 포트 | 프로토콜 | 소스 |
|---|---|---|---|
| in | 8080 | TCP | `alb_sg` |
| in | 80 | TCP | `alb_sg` |
| in | 443 | TCP | `alb_sg` |
| in | 22 | TCP | `openvpn_sg` |
| out | 전체 | 전체 | `0.0.0.0/0` |

- 애플리케이션 서버는 ALB로부터의 트래픽(80/443/8080)과 OpenVPN을 통한 SSH(22)만 허용 — CIDR 없이 전부 **SG 참조**로만 구성되어 있어, 앱 서버가 인터넷에서 직접 도달 불가능한 구조입니다.

**`db_sg`**
| 방향 | 포트 | 프로토콜 | 소스 |
|---|---|---|---|
| in | 3306 | TCP | `app_sg` |
| in | 3306 | TCP | `openvpn_sg` |
| in | 22 | TCP | `openvpn_sg` |
| out | 전체 | 전체 | `0.0.0.0/0` |

- DB는 앱 서버(3306), 관리자(OpenVPN 경유 3306/22)에서만 접근 가능 — 역시 전부 SG 참조 방식이며 퍼블릭 CIDR 인바운드가 전혀 없습니다.

**`monitoring_sg`** (`modules/monitoring-ec2/main.tf` — 공용 `security_groups` 모듈과 별도로 정의됨)
| 방향 | 포트 | 프로토콜 | 소스 | 비고 |
|---|---|---|---|---|
| in | 9090 | TCP | `0.0.0.0/0` | Prometheus 웹 UI |
| in | 6180 | TCP | `0.0.0.0/0` | Scouter Web UI |
| in | 6100 | TCP | `0.0.0.0/0` | Scouter Agent 통신(TCP) |
| in | 6100 | UDP | `0.0.0.0/0` | Scouter Agent 통신(UDP) |
| in | 22 | TCP | `0.0.0.0/0` | SSH |
| out | 전체 | 전체(`-1`) | `0.0.0.0/0` | 전체 허용 |

- 총 5개 인그레스 규칙(포트 9090/6180/6100(TCP)/6100(UDP)/22)이 **전부 `0.0.0.0/0`**에 개방되어 있습니다. 코드 내 주석("테스트용", "보안 시 YOUR_IP로 제한")으로 미루어 작성자도 이를 임시 개방 상태로 인지하고 있는 것으로 보입니다.
- ⚠️ 공용 `security_groups` 모듈의 `app_sg`/`db_sg`는 SG 참조만 사용하는 최소 권한 구조가 지켜진 반면, `monitoring_sg`는 SSH(22)까지 포함한 모든 포트가 `openvpn_sg`와 같은 수준으로 `0.0.0.0/0`에 열려 있어 — 최소 권한 원칙이 공용 SG 모듈만큼 일관되게 적용되지 않은 예외 지점입니다.

### 3-3. 보안 그룹 간 참조 구조 (SG-to-SG)

```
                 0.0.0.0/0
                     │ (80,443,8080)
                     ▼
                 alb_sg ──────────┐
                     │            │(80,443,8080)
                     │            ▼
0.0.0.0/0            │         app_sg
(1194,22,945,443,943) │            ▲
     ▼                │            │(22)
 openvpn_sg ──────────┴────────────┘
     │        (22, 3306)
     └───────────────────────────► db_sg
                                     ▲
                                     │ (3306)
                                  app_sg
```

- 참조 방향: `alb_sg → app_sg`(HTTP/HTTPS/8080), `openvpn_sg → app_sg`(SSH), `app_sg → db_sg`(MySQL), `openvpn_sg → db_sg`(MySQL, SSH)
- `db_sg`와 `app_sg`는 **CIDR 블록 인바운드 규칙이 전혀 없고 오직 SG 참조만 사용** — "직접 인터넷 노출 없음" 원칙이 코드 수준에서 명확히 지켜지고 있습니다.
- `openvpn_sg`는 유일하게 `0.0.0.0/0`으로 열린 SG이며, 동시에 `app_sg`/`db_sg`에 대한 SSH/MySQL 우회 경로 역할도 겸하고 있어 **사실상 전체 인프라에 대한 관리자 접근 허브**입니다. openvpn_sg가 곧 전체 네트워크 보안의 단일 신뢰 지점(trust anchor)이라는 의미이기도 합니다.

---

## 4. 네트워크 설계 의도 분석

### 4-1. 퍼블릭/프라이빗 분리 이유

- ALB, NAT, OpenVPN처럼 인터넷과 직접 통신해야 하는 리소스만 퍼블릭 서브넷(`map_public_ip_on_launch=true`)에 두고, 실제 비즈니스 로직을 수행하는 앱 서버와 DB는 프라이빗 서브넷에 격리했습니다.
- 앱과 DB조차 같은 "프라이빗"으로 묶지 않고 별도 계층(`private_app` / `private_db`)으로 나눈 것은, DB를 앱 서버보다 한 단계 더 안쪽에 두어 설사 앱 서버가 침해당하더라도 DB 접근에 추가적인 SG 경계(app_sg→db_sg)를 거치도록 하는 3-tier 방어 심층화(defense in depth) 의도로 해석됩니다.
- 프라이빗 서브넷도 NAT를 통해 아웃바운드 인터넷은 가능하게 하여(패키지 설치, 외부 API 호출 등) 운영 편의성과 격리 사이의 균형을 취하고 있습니다.

### 4-2. 고가용성(HA) 고려 여부

- **부분적으로 고려됨**: 서브넷/라우트 테이블은 `ap-northeast-2a`/`2c` 2개 AZ에 걸쳐 이중화되어 있고, ASG(앱 서버)도 `private_app_subnet_ids`(2개 AZ) 전체를 `vpc_zone_identifier`로 사용하므로 앱 계층은 AZ 장애에 대응 가능합니다.
- **미흡한 부분**: NAT 게이트웨이가 1개(2a 전용)뿐이라 네트워크 계층에서는 단일 장애점이 존재합니다. AWS 권장 아키텍처(AZ별 NAT + EIP)에는 못 미치며, 비용 절감을 우선한 구성으로 보입니다.
- DB는 `database-ec2` 모듈이 EC2 기반 단일 인스턴스(`aws_instance`, RDS Multi-AZ 아님)로 구성되어 있어(step2 분석 참고), DB 계층 자체의 HA는 애초에 고려되어 있지 않습니다 — 서브넷만 2-AZ로 준비되어 있을 뿐 실제 DB 인스턴스는 이중화되어 있지 않은 것으로 보입니다.

### 4-3. 보안 설계 원칙 (최소 권한 원칙 적용 여부)

- **잘 적용된 부분**: `app_sg`, `db_sg`는 CIDR 인바운드 없이 오직 필요한 SG 참조만 허용하는 전형적인 최소 권한 구조입니다. 라우팅 레벨에서도 프라이빗 서브넷은 IGW 직접 경로가 없어 NAT를 통한 아웃바운드만 가능합니다.
- **개선 여지가 있는 부분**:
  1. `openvpn_sg`가 5개 포트(1194/22/945/443/943)를 모두 `0.0.0.0/0`에 개방 — 관리 목적이라도 사내 고정 IP 대역 등으로 제한하는 것이 최소 권한 원칙에 더 부합합니다.
  2. `alb_sg`의 `8080` 인바운드가 `0.0.0.0/0`으로 열려 있는데, ALB가 실제로 외부에서 8080으로 요청을 받을 필요가 있는지 확인이 필요합니다(불필요하다면 제거 대상).
  3. `egress`가 4개 SG 모두 `0.0.0.0/0` / 전체 포트로 완전 개방되어 있어, 아웃바운드 방향의 최소 권한은 적용되어 있지 않습니다(일반적인 관행이긴 하나, DB/APP 서버의 아웃바운드를 제한하면 데이터 유출(exfiltration) 경로를 줄일 수 있습니다).
  4. NAT 단일 구성과 결합하면, 프라이빗 서브넷의 모든 리소스가 결국 하나의 아웃바운드 경로(단일 NAT)를 공유 — 네트워크 격리 원칙 자체는 맞지만 장애/모니터링 관점의 단일 집중점이기도 합니다.

---

## 요약

- **VPC**: 환경별 `/16` (dev `10.1.0.0/16`, prod `10.3.0.0/16`), 2-AZ(`2a`,`2c`) 구성, DNS 지원 활성화.
- **서브넷**: 퍼블릭/프라이빗-앱/프라이빗-DB 3계층 × 2AZ = 6개 서브넷, `/24` 고정 CIDR을 tfvars에 직접 명시.
- **라우팅**: IGW(퍼블릭), 단일 NAT(프라이빗 전체 공유, 2a 고정) — 비용 최적화형 구성이나 NAT는 SPOF.
- **보안그룹**: `security_groups` 모듈의 openvpn/alb/app/db 4종 + `monitoring-ec2` 모듈 자체 보유 `monitoring_sg` 1종, 총 5종. app·db는 SG 참조만 사용하는 최소 권한 구조가 잘 지켜짐, 다만 openvpn_sg의 광범위한 `0.0.0.0/0` 개방, alb_sg의 8080 공개, monitoring_sg의 SSH(22) 포함 전체 포트 `0.0.0.0/0` 개방은 재검토 대상.
- **설계 의도**: 3-tier 심층 방어 + 2-AZ HA를 지향하나, NAT 이중화와 DB 이중화(RDS Multi-AZ 등)는 아직 반영되지 않은 초기~중간 단계의 운영급 구성으로 평가됩니다.
