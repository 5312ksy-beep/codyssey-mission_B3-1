# 트러블슈팅 · 헬스체크 경로에서 404 응답

2026-11-26, Windows의 Nginx 1.30.8에서 프로젝트 `web/default.conf`로 재현했다. 호스트 경로와 리슨 주소를 로컬 환경(`127.0.0.1:18431`)에 맞춰 썼다.

| 단계 | 확인한 내용 |
|---|---|
| 증상 | `/health`가 기대값인 HTTP 200 대신 HTTP 404를 반환했다. |
| 가설 | 요청이 Nginx에 도달했지만 헬스체크의 정확 일치 경로를 `/healthz`로 잘못 등록했을 것으로 가정했다. |
| 검증 | 같은 호스트에서 `/health`는 404, `/healthz`는 200과 `OK`를 반환했다. Nginx access log에 두 요청이 모두 기록되어 서버까지 요청이 도달했음을 확인했다. |
| 조치 | `location = /healthz`를 `location = /health`로 복구했다. `nginx -t`로 설정 검사를 통과한 뒤 reload했다. |
| 결과 | `/health`는 200과 `OK`, `/`는 200과 B3-1 HTML, 이전 경로인 `/healthz`는 404를 반환했다. |
| 재발 방지 | Docker 헬스체크와 외부 검증에서 동일한 `/health`를 사용한다. 외부 검증은 상태 코드가 200이고 본문이 `OK`일 때만 통과한다. |

Nginx access log 발췌

```text
127.0.0.1 - - [26/Nov/2026:23:43:01 +0900] "GET /healthz HTTP/1.1" 200 3
127.0.0.1 - - [26/Nov/2026:23:43:01 +0900] "GET /health HTTP/1.1" 404 146
127.0.0.1 - - [26/Nov/2026:23:43:02 +0900] "GET /health HTTP/1.1" 200 3
127.0.0.1 - - [26/Nov/2026:23:43:02 +0900] "GET / HTTP/1.1" 200 1100
127.0.0.1 - - [26/Nov/2026:23:43:02 +0900] "GET /healthz HTTP/1.1" 404 146
```

## AWS에서 증상을 확인하는 순서

1. **라우팅** · 실제 서브넷에 연결된 라우팅 테이블에서 `0.0.0.0/0 → igw-…`가 `active`인지, 해당 IGW가 VPC에 연결되어 있는지 확인한다.
2. **보안 그룹** · EC2에 붙은 그룹에서 HTTP는 TCP 80, SSH는 TCP 22 및 현재 접속 PC의 공인 IPv4 `/32`인지 확인한다. 커스텀 Network ACL이 있으면 왕복 트래픽도 확인한다.
3. **공인 주소** · Stack Outputs의 EIP가 현재 EC2에 연결되어 있는지 확인한다. 도메인을 쓰는 경우 먼저 IP로 접속하고, DNS A 레코드가 같은 IP를 가리키는지 확인한다.
4. **서버와 로그** · SSH로 접속해 아래 명령을 순서대로 실행한다. 요청이 로그에 도착했는지, Nginx가 어떤 코드를 보냈는지 확인한 뒤 확인된 원인만 수정한다.

```bash
curl -i http://localhost/
curl -i http://localhost/health
sudo docker ps -a --filter name=codyssey-b3-1
sudo docker logs --tail 30 codyssey-b3-1
sudo tail -n 60 /var/log/cloud-init-output.log
sudo tail -n 60 /var/log/codyssey-b3-1.log
```
