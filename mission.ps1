#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Deploy', 'Verify', 'Cleanup')] [string]$Action,
    [Parameter(Mandatory)] [string]$Profile,
    [string]$AdminCidr,
    [string]$PublicKeyPath,
    [string]$PrivateKeyPath,
    [switch]$FreeTierChecked
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Region = 'ap-northeast-2'
$Stack = 'codyssey-b3-1'
$WorkingDir = Join-Path $PSScriptRoot '.mission'
$env:AWS_PAGER = ''

function Invoke-Aws {
    $result = & aws @args --region $Region --profile $Profile --output json
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: $($args[0]) $($args[1])" }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Write-Utf8($Path, $Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Read-Template {
    $files = @{
        '__INDEX_BASE64__' = 'web/index.html'
        '__NGINX_BASE64__' = 'web/default.conf'
    }
    $bootstrap = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'infra/bootstrap.sh')).Replace("`r`n", "`n")
    foreach ($marker in $files.Keys) {
        $content = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $files[$marker]))
        $bootstrap = $bootstrap.Replace($marker, [Convert]::ToBase64String($content))
    }
    $data = [Text.Encoding]::UTF8.GetBytes($bootstrap)
    if ($data.Length -gt 16384) { throw 'EC2 user data exceeds 16 KiB.' }
    $template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'infra/template.yml'))
    $template.Replace('__BOOTSTRAP_BASE64__', [Convert]::ToBase64String($data))
}

function Get-Stack {
    (Invoke-Aws cloudformation describe-stacks --stack-name $Stack).Stacks[0]
}

function Get-Inventory {
    $tag = "Name=tag:Project,Values=$Stack"
    $instances = (Invoke-Aws ec2 describe-instances --filters $tag).Reservations.Instances
    $volumes = (Invoke-Aws ec2 describe-volumes --filters $tag).Volumes
    [ordered]@{
        Instance = @($instances | Where-Object { $_ } | ForEach-Object {
            [ordered]@{ Id = $_.InstanceId; State = $_.State.Name }
        })
        Volume = @(@($volumes.VolumeId) + @($instances.BlockDeviceMappings.Ebs.VolumeId) |
            Where-Object { $_ } | Sort-Object -Unique)
        ElasticIp = @((Invoke-Aws ec2 describe-addresses --filters $tag).Addresses.AllocationId | Where-Object { $_ })
        InternetGateway = @((Invoke-Aws ec2 describe-internet-gateways --filters $tag).InternetGateways.InternetGatewayId | Where-Object { $_ })
        Vpc = @((Invoke-Aws ec2 describe-vpcs --filters $tag).Vpcs.VpcId | Where-Object { $_ })
        Subnet = @((Invoke-Aws ec2 describe-subnets --filters $tag).Subnets.SubnetId | Where-Object { $_ })
        RouteTable = @((Invoke-Aws ec2 describe-route-tables --filters $tag).RouteTables.RouteTableId | Where-Object { $_ })
        SecurityGroup = @((Invoke-Aws ec2 describe-security-groups --filters $tag).SecurityGroups.GroupId | Where-Object { $_ })
        KeyPair = @((Invoke-Aws ec2 describe-key-pairs --filters $tag).KeyPairs.KeyPairId | Where-Object { $_ })
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'Install AWS CLI v2 and configure an IAM profile.' }
$identity = Invoke-Aws sts get-caller-identity
if ($identity.Arn -notmatch ':(user/|assumed-role/)') { throw 'Use a non-root IAM user or assumed role.' }
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null
$accountDir = Join-Path $WorkingDir $identity.Account
New-Item -ItemType Directory -Path $accountDir -Force | Out-Null

switch ($Action) {
    Deploy {
        if (-not $FreeTierChecked) { throw 'Check Billing and the Free Tier before setting -FreeTierChecked.' }
        if (-not $AdminCidr -or -not $PublicKeyPath) { throw 'Specify -AdminCidr and -PublicKeyPath.' }
        $cidrPattern = '^(?!0\.0\.0\.0/32$)(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/32$'
        if ($AdminCidr -notmatch $cidrPattern) { throw 'SSH must use a single public IPv4 address (/32).' }
        $key = (Get-Content -Raw -LiteralPath $PublicKeyPath).Trim()
        if ($key -notmatch '^ssh-ed25519 ([A-Za-z0-9+/=]+)(?:[ \t]+[^\r\n]*)?$') {
            throw 'Supply only the .pub file from ssh-keygen -t ed25519.'
        }
        $key = "ssh-ed25519 $($Matches[1])"
        $image = (Invoke-Aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64).Parameter.Value
        $ami = (Invoke-Aws ec2 describe-images --image-ids $image --owners amazon).Images | Select-Object -First 1
        if (-not $ami -or $ami.State -ne 'available' -or $ami.Architecture -ne 'x86_64' -or $ami.RootDeviceName -ne '/dev/xvda') {
            throw 'The public AL2023 AMI did not match the expected architecture and root device.'
        }
        $templatePath = Join-Path $accountDir 'template.yml'
        $paramsPath = Join-Path $accountDir 'parameters.json'
        Write-Utf8 $templatePath (Read-Template)
        $parameters = @(
            @{ ParameterKey = 'AdminCidr'; ParameterValue = $AdminCidr }
            @{ ParameterKey = 'PublicKey'; ParameterValue = $key }
            @{ ParameterKey = 'AmiId'; ParameterValue = $image }
        )
        Write-Utf8 $paramsPath (ConvertTo-Json -InputObject $parameters)
        Invoke-Aws cloudformation validate-template --template-body "file://$templatePath" | Out-Null
        $created = Invoke-Aws cloudformation create-stack --stack-name $Stack --template-body "file://$templatePath" `
            --parameters "file://$paramsPath" --tags "Key=Project,Value=$Stack" --on-failure ROLLBACK
        Write-Host "Creating $($created.StackId)"
        try {
            Invoke-Aws cloudformation wait stack-create-complete --stack-name $created.StackId
        } catch {
            (Invoke-Aws cloudformation describe-stack-events --stack-name $created.StackId).StackEvents |
                Where-Object { $_.ResourceStatus -like '*FAILED' } |
                Format-Table LogicalResourceId, ResourceStatusReason -Wrap | Out-Host
            throw
        }
        (Get-Stack).Outputs | Format-Table OutputKey, OutputValue -AutoSize
    }
    Verify {
        if (-not $PrivateKeyPath) { throw 'Specify -PrivateKeyPath for the SSH check.' }
        $key = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
        $description = Get-Stack
        if ($description.StackStatus -ne 'CREATE_COMPLETE') { throw "Stack status: $($description.StackStatus)" }
        $ip = ($description.Outputs | Where-Object OutputKey -eq PublicIp).OutputValue
        $url = ($description.Outputs | Where-Object OutputKey -eq HealthUrl).OutputValue
        $cidr = ($description.Parameters | Where-Object ParameterKey -eq AdminCidr).ParameterValue
        $inventory = Get-Inventory
        if ($inventory.Subnet.Count -ne 1 -or $inventory.RouteTable.Count -ne 1 -or
            $inventory.InternetGateway.Count -ne 1 -or $inventory.Vpc.Count -ne 1 -or
            $inventory.SecurityGroup.Count -ne 1 -or $inventory.ElasticIp.Count -ne 1) {
            throw 'Unexpected number of network resources. Inspect the stack and Project tag.'
        }
        $gateway = (Invoke-Aws ec2 describe-internet-gateways --internet-gateway-ids $inventory.InternetGateway[0]).InternetGateways[0]
        $route = (Invoke-Aws ec2 describe-route-tables --route-table-ids $inventory.RouteTable[0]).RouteTables[0]
        $defaultRoute = $route.Routes | Where-Object DestinationCidrBlock -eq '0.0.0.0/0'
        if ($gateway.Attachments.VpcId -notcontains $inventory.Vpc[0] -or
            $route.VpcId -ne $inventory.Vpc[0] -or $route.Associations.SubnetId -notcontains $inventory.Subnet[0] -or
            $defaultRoute.GatewayId -ne $inventory.InternetGateway[0] -or $defaultRoute.State -ne 'active') {
            throw 'Expected an active 0.0.0.0/0 route from the public subnet to the attached IGW.'
        }
        $group = (Invoke-Aws ec2 describe-security-groups --group-ids $inventory.SecurityGroup[0]).SecurityGroups[0]
        $expected = @("tcp/22/22:$cidr", 'tcp/80/80:0.0.0.0/0')
        $actual = @(foreach ($rule in $group.IpPermissions) {
            if ($rule.Ipv6Ranges -or $rule.UserIdGroupPairs -or $rule.PrefixListIds) { throw 'Unexpected ingress sources.' }
            foreach ($range in $rule.IpRanges) { "$($rule.IpProtocol)/$($rule.FromPort)/$($rule.ToPort):$($range.CidrIp)" }
        })
        if ($actual.Count -ne 2 -or (Compare-Object $expected $actual)) { throw 'Unexpected Security Group ingress rules.' }
        $address = (Invoke-Aws ec2 describe-addresses --allocation-ids $inventory.ElasticIp[0]).Addresses[0]
        $instance = (Invoke-Aws ec2 describe-instances --instance-ids $address.InstanceId).Reservations.Instances
        if ($address.PublicIp -ne $ip -or $instance.State.Name -ne 'running' -or
            $instance.SubnetId -ne $inventory.Subnet[0] -or @($instance.SecurityGroups.GroupId).Count -ne 1 -or
            $instance.SecurityGroups.GroupId -ne $group.GroupId) { throw 'Unexpected EC2 or EIP configuration.' }
        Write-Host "Route: $($route.RouteTableId) 0.0.0.0/0 -> $($defaultRoute.GatewayId)"
        Write-Host "Ingress: $($actual -join ', ')"

        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        $ready = $false
        do {
            $response = @(& curl.exe --silent --noproxy '*' --max-time 6 --fail --write-out '%{http_code}' $url)
            $ready = $LASTEXITCODE -eq 0 -and $response.Count -eq 2 -and
                $response[0] -ceq 'OK' -and $response[1] -eq '200'
            if ($ready) { break }
            Start-Sleep -Seconds 5
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $ready) { throw "Health check failed. Inspect cloud-init and Docker logs over SSH. URL: $url" }
        Write-Host "GET $url"
        & curl.exe --noproxy '*' --max-time 8 --fail --silent --show-error --include $url
        if ($LASTEXITCODE -ne 0) { throw 'External HTTP check failed.' }

        $remote = "set -e; hostname; sudo docker ps --filter name=codyssey-b3-1; curl -fsS -o /dev/null -w 'localhost: %{http_code}\n' --max-time 10 http://localhost/; curl -fsS -o /dev/null -w 'outbound: %{http_code}\n' --max-time 12 https://example.com/"
        & ssh -i $key -o IdentitiesOnly=yes -o ConnectTimeout=10 "ec2-user@$ip" $remote
        if ($LASTEXITCODE -ne 0) { throw 'SSH or an EC2-side check failed. Check the SSH CIDR, key, and service output.' }

        $record = [ordered]@{ CheckedAtUtc = [DateTime]::UtcNow.ToString('o'); Method = 'B'; HealthUrl = $url;
            Route = '0.0.0.0/0 -> IGW'; Ingress = $actual; SshAndOutbound = 'Passed'; Resources = $inventory }
        Write-Utf8 (Join-Path $accountDir 'verification.json') ($record | ConvertTo-Json -Depth 8)
        Write-Host 'Verification passed. Capture the actual terminal output before cleanup.'
    }
    Cleanup {
        $beforePath = Join-Path $accountDir 'before-cleanup.json'
        $cleanupPath = Join-Path $accountDir 'cleanup.json'
        $id = $null
        try {
            $id = (Get-Stack).StackId
        } catch {
            if (-not (Test-Path -LiteralPath $beforePath)) { throw }
            $id = (Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json).StackId
        }
        $status = (Invoke-Aws cloudformation describe-stacks --stack-name $id).Stacks[0].StackStatus
        if ($status -notin @('DELETE_IN_PROGRESS', 'DELETE_COMPLETE')) {
            $before = [ordered]@{ CheckedAtUtc = [DateTime]::UtcNow.ToString('o'); StackId = $id; Resources = Get-Inventory }
            $saved = if (Test-Path -LiteralPath $beforePath) { Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json }
            if (-not $saved -or $saved.StackId -ne $id) {
                Write-Utf8 $beforePath ($before | ConvertTo-Json -Depth 8)
            }
            Invoke-Aws cloudformation delete-stack --stack-name $id
        }
        if ($status -ne 'DELETE_COMPLETE') {
            Invoke-Aws cloudformation wait stack-delete-complete --stack-name $id
        }
        $before = Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json
        $after = Get-Inventory
        $volumeIds = $before.Resources.Volume -join ','
        if ($volumeIds) {
            $previousVolumes = (Invoke-Aws ec2 describe-volumes --filters "Name=volume-id,Values=$volumeIds").Volumes
            $after.Volume = @($after.Volume + @($previousVolumes.VolumeId) | Where-Object { $_ } | Sort-Object -Unique)
        }
        $after.Instance = @($after.Instance | Where-Object State -ne 'terminated')
        $passed = -not ($after.Values | Where-Object { $_.Count -gt 0 })
        $cleanup = [ordered]@{ CheckedAtUtc = [DateTime]::UtcNow.ToString('o'); StackStatus = 'DELETE_COMPLETE';
            Passed = $passed; Before = $before.Resources; Remaining = $after }
        $json = $cleanup | ConvertTo-Json -Depth 8
        Write-Utf8 $cleanupPath $json
        Write-Output $json
        if (-not $passed) { throw 'Project resources remain. Inspect cleanup.json before removing individual resources.' }
    }
}
