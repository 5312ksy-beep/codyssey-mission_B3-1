# 평가 대비 · 예상 질문과 답변

## 항목 1 · 실행 결과는 어디서 확인하나요?

`Verify`로 Public Subnet에 연결된 `0.0.0.0/0 → IGW` 경로, EC2의 EIP 연결, SSH와 웹 서버 응답을 확인한다. `01-external-health.png`에서 외부 `GET /health`의 200과 `OK`를, `02-ssh-docker.png`에서 SSH, `docker ps`, EC2 내부 200, 인터넷 아웃바운드 200을 확인한다. 종료 후에는 [정리 체크리스트](cleanup-checklist.md)의 EC2, EBS, EIP, IGW, VPC 다섯 행에 실제 정리 근거를 기록한다.

## 항목 2 · 트래픽은 어떻게 들어오나요?

- **외부 PC → IGW → Public Subnet → EC2** 순서다. 외부 PC가 EC2의 EIP로 요청을 보내면 IGW가 퍼블릭 IPv4와 EC2의 프라이빗 IPv4 간 매핑을 처리한다. EC2 네트워크 인터페이스의 SG가 출발지와 포트를 확인하고, 허용된 TCP 80 요청은 Docker를 통해 Nginx에 도달한다.
- 웹 서비스는 누구나 이용할 수 있도록 `0.0.0.0/0`에서 TCP 80을 허용했다. SSH는 관리 작업에만 필요해 학습자 PC의 공인 IPv4 `/32`로 제한했다. DB와 기타 인바운드 포트는 닫았다.
- 고정 응답을 확인할 수 있는 B 방식을 골랐다. Nginx에 `location = /health`를 두어 HTTP 200과 `OK`를 반환하게 하고, EC2 바깥에서 호출한다. 주소를 바꾸지 않고 증빙을 남길 수 있도록 EIP를 연결했다.
- `Project=codyssey-b3-1` 태그, `codyssey-b3-1-` 이름, CloudFormation 스택, 삭제 전후 목록과 체크리스트를 함께 사용한다. EBS도 인스턴스 태그를 받으며 EIP는 Allocation ID로 추적한다.

## 항목 3 · 왜 이런 설정을 했나요?

- VPC의 `local` 경로는 VPC 내부 CIDR에 적용된다. `0.0.0.0/0 → IGW`는 더 구체적인 대상 경로가 없는 IPv4 트래픽을 IGW로 보낸다. 따라서 퍼블릭 IP를 가진 EC2가 외부와 왕복하려면 해당 서브넷의 라우팅 테이블에 이 경로가 필요하다.
- **Security Group**은 EC2의 네트워크 트래픽을 제어하는 상태 저장 방화벽이다. **IAM**은 AWS API를 누가 어떤 리소스에 호출할 수 있는지 제어한다. 실습용 IAM 정책은 스택과 리전, EC2 작업, 공식 AMI 조회 범위를 제한한다. 권한을 좁히면 설정 실수나 자격 증명 유출이 다른 서비스에 미치는 영향을 줄인다.
- SSH와 DB 포트를 전 세계에 열면 무차별 로그인 시도나 노출된 서비스를 대상으로 한 접근이 들어온다. SSH는 신뢰하는 공인 IPv4 `/32`로 제한하거나 VPN·Session Manager를 사용한다. DB는 프라이빗 서브넷에 두고 앱의 SG에서만 DB 포트에 접근하도록 한다.
- 증상에서 가설을 세운 뒤 명령 출력과 로그로 검증하면 원인을 좁히고 조치 전후를 비교할 수 있다. 404 재현에서는 Nginx access log가 요청 도착을 보여 줬고 두 경로의 응답 차이가 설정 오류를 알려 줬다. [트러블슈팅 보고서](troubleshooting.md)

## 항목 4 · 문제가 생기거나 규모가 커지면 어떻게 하나요?

| 상황 | 대응 |
|---|---|
| 외부에서 접속 불가 | 서브넷의 실제 Route Table과 IGW 연결 → 인바운드 SG → EIP 연결·DNS → `curl localhost`, `docker ps`, Nginx와 cloud-init 로그 순으로 확인한다. 외부 요청과 내부 요청의 결과를 비교해 실패 지점을 좁힌다. |
| `AccessDenied` | CloudFormation Events에서 실패한 리소스와 API, 요청 주체를 확인한다. 필요하면 계정 담당자와 CloudTrail의 이벤트를 대조한다. [서비스 권한 표](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)에서 해당 작업이 지원하는 리소스 ARN과 조건을 찾아 해당 작업만 추가하고 재시도한다. 권한 경계나 SCP가 있는 계정에서는 담당자와 유효 권한을 함께 검토한다. |
| EC2 한 대로 트래픽 처리 어려움 | CPU, 연결 수, 응답 시간, 5xx를 먼저 확인한다. 단일 인스턴스가 병목이자 장애 지점이므로, 서로 다른 가용 영역에 서브넷과 EC2를 두고 ALB와 Target Group을 추가한다. ALB는 `/health`가 200인 인스턴스로 라우팅한다. EC2의 인바운드는 ALB 보안 그룹에서만 허용하고, 트래픽 변동이 크면 Auto Scaling을 검토한다. |
| 예상하지 못한 비용 | Billing의 서비스·리전·사용 유형을 확인하고 공개 IPv4(EIP), 실행 중인 EC2, 남은 EBS·스냅샷을 먼저 조회한다. 실습 중 별도 생성했다면 NAT Gateway, ALB, RDS도 확인한다. 태그, 스택 목록, 삭제 전 ID를 대조해 실습 자원만 정리하고 Billing 업데이트 후 다시 확인한다. |

## IAM 적용 범위

[실습용 정책](../iam/learner-policy.json)은 전용 IAM 사용자 또는 Role에 적용한다. CloudFormation은 이를 통해 네트워크와 인스턴스를 생성하고 삭제하며, `ssm:GetParameter`는 Amazon Linux 공식 AMI 한 건을 해석하는 데 사용한다. EC2에는 IAM 인스턴스 프로필을 할당하지 않는다. 일부 EC2 조회와 생성 작업은 여러 리소스를 한 번에 평가하므로 조회·작업 목록과 리전으로 범위를 제한했다. 과제 태그가 붙은 인스턴스와 EBS만 정책으로 종료·삭제할 수 있다. 기존에 계정의 다른 권한이 합쳐진다면 최종 권한을 계정 담당자와 확인한다. [CloudFormation IAM 문서](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/control-access-with-iam.html)
