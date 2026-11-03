Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../AgentDiagnostics.psm1') -Force -PassThru
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -cne $Expected) { throw "$Name expected [$Expected], got [$Actual]." }
    $script:checks++
}

$assessment = Get-AgentResponseAssessment -ToolInvoked Yes -BackendOutcome Success -AgentOutput Content -ChannelOutput Empty
Assert-Equal $assessment.Gates[0].Code 'REVIEW_CHANNEL_DELIVERY' 'Channel boundary'
$assessment = Get-AgentResponseAssessment -ToolInvoked No -BackendOutcome Unknown -AgentOutput Empty -ChannelOutput Empty
Assert-Equal $assessment.Gates[0].Code 'REVIEW_ORCHESTRATION' 'Orchestration boundary'
$assessment = Get-AgentResponseAssessment -ToolInvoked Yes -BackendOutcome Empty -AgentOutput Empty -ChannelOutput Empty
Assert-Equal $assessment.Gates[0].Code 'REVIEW_RETRIEVAL_OR_TOOL_RESULT' 'Retrieval boundary'
$assessment = Get-AgentResponseAssessment -ToolInvoked Yes -BackendOutcome Success -AgentOutput Content -ChannelOutput Content
Assert-Equal $assessment.Status 'PASSED' 'Observed content'
Assert-Equal $assessment.ApplicationAcceptance 'NOT_TESTED' 'No automatic acceptance'
$assessment = Get-AgentResponseAssessment -ToolInvoked No -BackendOutcome Success -AgentOutput Empty -ChannelOutput Empty
Assert-Equal $assessment.Gates[0].Code 'CONFLICTING_EVIDENCE' 'Contradictory inputs'

& $module {
    $message = Get-RpcMessage '{"jsonrpc":"2.0","id":1,"result":{}}' 'application/json' 1
    if ($null -eq $message) { throw 'JSON RPC response was not parsed.' }
    $message = Get-RpcMessage "event: message`ndata: {`"jsonrpc`":`"2.0`",`"id`":1,`"result`":{}}`n`n" 'text/event-stream' 1
    if ($null -eq $message) { throw 'SSE RPC response was not parsed.' }
    $message = Get-RpcMessage '{"jsonrpc":"2.0","id":2,"result":{}}' 'application/json' 1
    if ($null -ne $message) { throw 'Mismatched RPC ID was accepted.' }
}
$script:checks += 3

foreach ($endpoint in @('http://example.invalid', 'https://example.invalid/?secret=hidden', 'https://user:password@example.invalid')) {
    $rejected = $false
    try { Test-AgentHttpsEndpoint -Endpoint $endpoint | Out-Null } catch { $rejected = $true }
    Assert-Equal $rejected $true 'Unsafe endpoint rejected before transport'
}

& $module {
    function Invoke-DiagnosticHttp {
        param($Endpoint, $Method, $Headers, $Body, $TimeoutSeconds, $MaxResponseBytes, $RequestId, [switch]$Rpc, [switch]$Notification, [switch]$HeadersOnly)
        $data = $null
        if ($HeadersOnly) { return [pscustomobject]@{ StatusCode = 401; Code = 'HTTP_RESPONSE'; Data = $null; SessionId = $null } }
        switch ($Body.method) {
            'initialize' { $data = [pscustomobject]@{ result = [pscustomobject]@{ protocolVersion = '2025-03-26'; capabilities = [pscustomobject]@{ tools = [pscustomobject]@{} } } } }
            'notifications/initialized' {
                if ($Headers['Mcp-Session-Id'] -ne 'synthetic-session') { throw 'Session not propagated.' }
                return [pscustomobject]@{ StatusCode = 202; Code = 'HTTP_RESPONSE'; Data = $null; SessionId = $null }
            }
            'tools/list' { $data = [pscustomobject]@{ result = [pscustomobject]@{ tools = @([pscustomobject]@{ name = 'synthetic_echo' }) } } }
            'tools/call' { $data = [pscustomobject]@{ result = [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = 'synthetic only' }) } } }
        }
        [pscustomobject]@{ StatusCode = 200; Code = 'HTTP_RESPONSE'; Data = $data; SessionId = 'synthetic-session' }
    }
    $result = Test-AgentMcpServer -Endpoint https://example.invalid/mcp
    if ($result.Gates[-1].Code -ne 'DISCOVERY_ONLY') { throw 'Discovery called a tool.' }
    $result = Test-AgentMcpServer -Endpoint https://example.invalid/mcp -AllowToolCall -ToolName synthetic_echo -Confirm:$false
    if ($result.Status -ne 'PASSED') { throw 'Approved MCP call failed.' }
    $result = Test-AgentMcpServer -Endpoint https://example.invalid/mcp -AllowToolCall -ToolName synthetic_echo -WhatIf
    if ($result.Gates[-1].Status -ne 'NOT_TESTED') { throw 'WhatIf invoked a tool.' }
    $result = Test-AgentHttpsEndpoint -Endpoint https://example.invalid
    if ($result.Gates[0].Status -ne 'PASSED' -or $result.Gates[1].Code -ne 'HTTP_401') { throw '401 conflated with unreachable endpoint.' }
}
$script:checks += 4

& $module {
    foreach ($case in @(
        @{ StatusCode = 403; Code = 'HTTP_RESPONSE'; Data = $null; Expected = 'FAILED' },
        @{ StatusCode = 0; Code = 'TIMEOUT'; Data = $null; Expected = 'INCONCLUSIVE' },
        @{ StatusCode = 200; Code = 'EMPTY_RESPONSE'; Data = $null; Expected = 'INCONCLUSIVE' },
        @{ StatusCode = 200; Code = 'HTTP_RESPONSE'; Data = @{ error = @{ code = -32601 } }; Expected = 'FAILED' }
    )) {
        $gate = Get-HttpGate 'Synthetic' ([pscustomobject]$case)
        if ($gate.Status -ne $case.Expected) { throw 'Failure classification mismatch.' }
    }
    $script:searchResult = @([pscustomobject]@{ id = 'synthetic-001' })
    function Invoke-DiagnosticHttp {
        param($Endpoint, $Method, $Headers, $Body, $TimeoutSeconds)
        if ($Endpoint.AbsolutePath -ne "/indexes('synthetic-index')/docs/search.post.search") { throw 'Wrong Search path.' }
        if ($Endpoint.Query -ne '?api-version=2024-07-01') { throw 'Wrong API version.' }
        if ($Body.select -ne 'id' -or $Body.search -ne 'synthetic') { throw 'Wrong Search payload.' }
        [pscustomobject]@{ StatusCode = 200; Code = 'HTTP_RESPONSE'; Data = [pscustomobject]@{ value = $script:searchResult }; SessionId = $null }
    }
    $parameters = @{ Endpoint = 'https://example.invalid'; IndexName = 'synthetic-index'; Headers = @{};
        SearchText = 'synthetic'; KeyField = 'id'; ExpectedKey = 'synthetic-001' }
    $result = Test-AgentSearchIndex @parameters
    if ($result.Status -ne 'PASSED') { throw 'Known document was not found.' }
    $script:searchResult = @()
    $result = Test-AgentSearchIndex @parameters
    if ($result.Gates[-1].Code -ne 'EXPECTED_KEY_NOT_IN_TOP_RESULTS') { throw 'Empty Search incorrectly passed.' }
    $script:searchResult = [pscustomobject]@{ id = 'synthetic-001' }
    $result = Test-AgentSearchIndex @parameters
    if ($result.Status -ne 'INCONCLUSIVE') { throw 'Malformed Search incorrectly passed.' }
}
$script:checks += 7
$module = Import-Module (Join-Path $PSScriptRoot '../AgentDiagnostics.psm1') -Force -PassThru

function Invoke-LoopbackFixture {
    param([string]$Body, [string]$ContentType = 'application/json', [int]$StatusCode = 200,
        [switch]$NoResponse, [scriptblock]$Action)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $server = [PowerShell]::Create()
    $null = $server.AddScript({
        param($Listener, $Body, $ContentType, $StatusCode, $NoResponse)
        $connection = $Listener.AcceptTcpClient()
        $stream = $connection.GetStream()
        try {
            $request = [Collections.Generic.List[byte]]::new()
            while ($true) {
                $nextByte = $stream.ReadByte()
                if ($nextByte -lt 0) { throw 'Client closed before request headers.' }
                $request.Add([byte]$nextByte)
                if ($request.Count -ge 4 -and [Text.Encoding]::ASCII.GetString($request.ToArray()).EndsWith("`r`n`r`n")) { break }
            }
            $requestHeaders = [Text.Encoding]::ASCII.GetString($request.ToArray())
            $contentLength = 0
            if ($requestHeaders -match '(?im)^Content-Length: (\d+)') { $contentLength = [int]$Matches[1] }
            for ($offset = 0; $offset -lt $contentLength; $offset++) {
                if ($stream.ReadByte() -lt 0) { throw 'Client closed before request body.' }
            }
            if ($NoResponse) {
                while ($stream.ReadByte() -ge 0) { }
            }
            else {
                $payload = [Text.Encoding]::UTF8.GetBytes($Body)
                $header = "HTTP/1.1 $StatusCode Synthetic`r`nContent-Type: $ContentType`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
                $bytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Write($payload, 0, $payload.Length)
                $stream.Flush()
            }
        }
        finally { $stream.Dispose(); $connection.Dispose() }
    }).AddArgument($listener).AddArgument($Body).AddArgument($ContentType).AddArgument($StatusCode).AddArgument([bool]$NoResponse)
    $pending = $server.BeginInvoke()
    try { & $Action ([uri]("http://127.0.0.1:{0}/" -f $port)) }
    finally {
        $listener.Stop()
        $server.EndInvoke($pending) | Out-Null
        $server.Dispose()
    }
}

Invoke-LoopbackFixture -Body '{"value":[{"id":"synthetic-001"}]}' -Action {
    param($Endpoint)
    $result = Test-AgentSearchIndex -Endpoint $Endpoint -IndexName synthetic-index -Headers @{} -SearchText synthetic -KeyField id -ExpectedKey synthetic-001 -AllowLoopbackHttp
    Assert-Equal $result.Status 'PASSED' 'Loopback Search response'
    Assert-Equal $result.ApplicationAcceptance 'NOT_TESTED' 'Search is not agent acceptance'
}
Invoke-LoopbackFixture -Body '{"sensitive":"must not appear"}' -StatusCode 401 -Action {
    param($Endpoint)
    $result = Test-AgentHttpsEndpoint -Endpoint $Endpoint -AllowLoopbackHttp
    Assert-Equal $result.Gates[-1].Code 'HTTP_401' 'Loopback unauthorized'
    Assert-Equal (($result | ConvertTo-Json -Depth 10) -match 'sensitive|must not appear') $false 'No error payload disclosure'
}
Invoke-LoopbackFixture -Body '' -StatusCode 302 -Action {
    param($Endpoint)
    $result = Test-AgentHttpsEndpoint -Endpoint $Endpoint -AllowLoopbackHttp
    Assert-Equal $result.Gates[-1].Code 'HTTP_302' 'Redirect not followed'
}
foreach ($payload in @('', '{not-json', '<html>login</html>')) {
    Invoke-LoopbackFixture -Body $payload -Action {
        param($Endpoint)
        $result = Test-AgentSearchIndex -Endpoint $Endpoint -IndexName synthetic-index -Headers @{} -SearchText synthetic -KeyField id -ExpectedKey synthetic-001 -AllowLoopbackHttp
        Assert-Equal $result.Status 'INCONCLUSIVE' 'Empty or invalid JSON response'
    }
}
Invoke-LoopbackFixture -Body "event: message`ndata: {`"jsonrpc`":`"2.0`",`"id`":1,`"result`":{`"protocolVersion`":`"unsupported`"}}`n`n" -ContentType text/event-stream -Action {
    param($Endpoint)
    $result = Test-AgentMcpServer -Endpoint $Endpoint -AllowLoopbackHttp
    Assert-Equal $result.Gates[1].Code 'UNSUPPORTED_PROTOCOL_VERSION' 'Loopback SSE parsing'
}
Invoke-LoopbackFixture -Body ('x' * 8192) -Action {
    param($Endpoint)
    $result = & $module { param($Uri) Invoke-DiagnosticHttp -Endpoint $Uri -Method GET -MaxResponseBytes 100 } $Endpoint
    Assert-Equal $result.Code 'RESPONSE_TOO_LARGE' 'Bounded body'
}
Invoke-LoopbackFixture -NoResponse -Action {
    param($Endpoint)
    $result = Test-AgentHttpsEndpoint -Endpoint $Endpoint -AllowLoopbackHttp -TimeoutSeconds 1
    Assert-Equal $result.Gates[0].Code 'TIMEOUT' 'Bounded request timeout'
}
Write-Host "Passed $script:checks local checks. Only loopback fixtures and in-memory mocks were used."