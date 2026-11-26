# 리소스 정리 체크리스트

- 리전은 `ap-northeast-2`, 스택은 `codyssey-b3-1`이다.
- 삭제 일시와 담당자는 삭제 후 기록한다.
- 실습 리소스는 `Project=codyssey-b3-1` 태그와 `codyssey-b3-1-` 이름으로 추적한다. 삭제 명령은 정리 전 리소스 ID와 정리 후 상태를 로컬 `.mission/<계정 번호>/`에 기록한다.

| 완료 | 리소스 | 확인 기준 | 실습 증빙 |
|---|---|---|---|
| ☐ | EC2 | 정리 전 인스턴스가 `terminated`이거나 조회 결과에서 사라짐 | 대기 |
| ☐ | EBS | 루트 볼륨과 태그로 확인한 실습 볼륨이 조회되지 않음 | 대기 |
| ☐ | Elastic IP | 정리 전 Allocation ID가 해제되어 EIP 목록에서 사라짐 | 대기 |
| ☐ | Internet Gateway | VPC에서 분리 후 삭제되어 조회되지 않음 | 대기 |
| ☐ | VPC | 정리 전 VPC가 조회되지 않음 | 대기 |
| ☐ | Public Subnet, Route Table, SG, AWS 키페어 | 각각 조회되지 않으며 스택은 `DELETE_COMPLETE` | 대기 |
| ☐ | Billing | 서울 리전의 EC2, EBS, 공인 IPv4 사용량·비용 확인 | 대기 |

NAT Gateway, ELB/ALB, RDS는 이 구성에서 생성하지 않는다. 실습 중 별도로 추가했다면 삭제 대상에 포함한다.

1. 외부 접속·SSH 스크린샷을 남긴 다음 `Cleanup`을 실행한다. CloudFormation은 EIP 연결이나 라우팅·IGW 연결 등의 의존 관계를 먼저 정리하고 스택 리소스를 삭제한다. 루트 EBS는 인스턴스 종료 시 같이 삭제된다.
2. `.mission/<계정 번호>/before-cleanup.json`과 `cleanup.json`을 비교한다. `Passed: true`이고 `Remaining`에 항목이 없을 때만 완료 표시를 하고, 표에 실제 ID 일부와 확인 상태를 남긴다. 필요하면 계정 정보를 가린 결과 화면을 `docs/evidence/03-cleanup.png`에 저장한다.
3. `DELETE_FAILED`이면 스택 **Events**에서 어떤 의존 리소스가 삭제를 막는지 확인한다. 예를 들어 별도로 만든 ENI가 같은 서브넷에 붙어 있다면 그 리소스의 소유와 사용 여부를 확인한 뒤 조치하고 `Cleanup`을 다시 실행한다. EBS나 EIP가 남으면 `cleanup.json`의 ID와 생성 시 저장한 목록을 비교한 뒤 해당 실습 리소스만 확인한다.
4. Billing에서 서울 리전의 EC2, EBS, 공인 IPv4 사용량과 비용을 확인한다. 사용량 반영에는 지연이 있을 수 있다. Billing 조회 권한이 분리된 계정이라면 해당 권한을 가진 담당자에게 확인을 요청한다. [AWS Free Tier 사용량 확인](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/tracking-free-tier-usage.html)
