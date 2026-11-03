#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Get-Field {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return ,$InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function New-Gate {
    param([string]$Name, [string]$Status, [string]$Code)
    [pscustomobject]@{ Gate = $Name; Status = $Status; Code = $Code }
}

function New-Assessment {
    param([string]$Kind, [string]$ExecutionLocation, [object[]]$Gates)
    $status = 'PASSED'
    if (@($Gates | Where-Object Status -eq 'FAILED').Count -gt 0) { $status = 'FAILED' }
    elseif (@($Gates | Where-Object Status -eq 'INCONCLUSIVE').Count -gt 0) { $status = 'INCONCLUSIVE' }
    elseif (@($Gates | Where-Object Status -eq 'NOT_TESTED').Count -gt 0) { $status = 'INCONCLUSIVE' }
    [pscustomobject]@{
        SchemaVersion = '1.0'
        Kind = $Kind
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
        ExecutionLocation = $ExecutionLocation
        LocationVerified = $false
        Status = $status
        Gates = $Gates
        ApplicationAcceptance = 'NOT_TESTED'
    }
}

function Assert-Endpoint {
    param([uri]$Endpoint, [switch]$AllowLoopbackHttp)
    if (-not $Endpoint.IsAbsoluteUri -or $Endpoint.UserInfo -or $Endpoint.Query -or $Endpoint.Fragment) {
        throw 'Use an absolute endpoint without embedded credentials, query, or fragment.'
    }
    if ($Endpoint.Scheme -eq 'https') { return }
    if ($AllowLoopbackHttp -and $Endpoint.Scheme -eq 'http' -and $Endpoint.IsLoopback) { return }
    throw 'HTTPS is required; HTTP is allowed only on loopback with explicit opt-in.'
}

function Get-RpcMessage {
    param([string]$Text, [string]$ContentType, [int]$RequestId)
    $messages = @()
    if ($ContentType -eq 'text/event-stream') {
        $eventBlocks = $Text.Replace("`r`n", "`n") -split "`n`n"
        for ($eventIndex = 0; $eventIndex -lt ($eventBlocks.Count - 1); $eventIndex++) {
            $eventBlock = $eventBlocks[$eventIndex]
            $data = @($eventBlock -split "`n" | Where-Object { $_ -match '^data:' } |
                ForEach-Object { $_.Substring(5).TrimStart(' ') }) -join "`n"
            if ($data) { $messages += @($data | ConvertFrom-Json -ErrorAction Stop) }
        }
    }
    else {
        $messages = @($Text | ConvertFrom-Json -ErrorAction Stop)
    }
    foreach ($message in $messages) {
        if ((Get-Field $message 'jsonrpc') -eq '2.0' -and (Get-Field $message 'id') -ceq $RequestId) {
            return $message
        }
    }
    return $null
}

function Invoke-DiagnosticHttp {
    param(
        [uri]$Endpoint, [string]$Method = 'POST', [hashtable]$Headers = @{},
        $Body, [int]$TimeoutSeconds = 20, [int]$MaxResponseBytes = 1048576,
        [int]$RequestId = 0, [switch]$Rpc, [switch]$Notification, [switch]$HeadersOnly
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.CheckCertificateRevocationList = $true
    $client = [Net.Http.HttpClient]::new($handler)
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Endpoint)
    $response = $null
    $stream = $null
    $buffered = [IO.MemoryStream]::new()
    try {
        foreach ($header in $Headers.Keys) {
            if ($header -match '^(Host|Content-Length|Content-Type|Accept)$') { throw 'Reserved header.' }
            if ([string]$Headers[$header] -match '[\r\n]') { throw 'Invalid request header.' }
            if (-not $request.Headers.TryAddWithoutValidation($header, [string]$Headers[$header])) {
                throw 'Invalid request header.'
            }
        }
        $accept = 'application/json'
        if ($Rpc -or $Notification) { $accept = 'application/json, text/event-stream' }
        $request.Headers.Accept.ParseAdd($accept)
        if ($null -ne $Body) {
            $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 30 -Compress),
                [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $sessionId = $null
        if ($response.Headers.Contains('Mcp-Session-Id')) {
            $sessionId = @($response.Headers.GetValues('Mcp-Session-Id'))[0]
        }
        $result = @{ StatusCode = $statusCode; Code = 'HTTP_RESPONSE'; Data = $null; SessionId = $sessionId }
        if ($statusCode -lt 200 -or $statusCode -ge 300 -or $HeadersOnly) {
            return [pscustomobject]$result
        }
        if ($Notification) {
            if ($statusCode -ne 202) { $result.Code = 'INVALID_NOTIFICATION_ACK' }
            return [pscustomobject]$result
        }
        $contentType = ''
        if ($null -ne $response.Content.Headers.ContentType) {
            $contentType = $response.Content.Headers.ContentType.MediaType
        }
        if ($contentType -ne 'application/json' -and -not ($Rpc -and $contentType -eq 'text/event-stream')) {
            $result.Code = 'UNSUPPORTED_CONTENT_TYPE'
            return [pscustomobject]$result
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = [byte[]]::new(4096)
        while ($true) {
            $bytesRead = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()
            if ($bytesRead -eq 0) { break }
            if ($buffered.Length + $bytesRead -gt $MaxResponseBytes) {
                $result.Code = 'RESPONSE_TOO_LARGE'
                return [pscustomobject]$result
            }
            $buffered.Write($buffer, 0, $bytesRead)
            if ($Rpc -and $contentType -eq 'text/event-stream') {
                $text = [Text.Encoding]::UTF8.GetString($buffered.ToArray())
                $message = Get-RpcMessage -Text $text -ContentType $contentType -RequestId $RequestId
                if ($null -ne $message) { $result.Data = $message; return [pscustomobject]$result }
            }
        }
        $text = [Text.Encoding]::UTF8.GetString($buffered.ToArray())
        if ([string]::IsNullOrWhiteSpace($text)) { $result.Code = 'EMPTY_RESPONSE' }
        elseif ($Rpc) {
            $result.Data = Get-RpcMessage -Text $text -ContentType $contentType -RequestId $RequestId
            if ($null -eq $result.Data) { $result.Code = 'RPC_ID_MISMATCH' }
        }
        else { $result.Data = $text | ConvertFrom-Json -ErrorAction Stop }
        return [pscustomobject]$result
    }
    catch {
        $code = 'TRANSPORT_OR_JSON_ERROR'
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [OperationCanceledException]) { $code = 'TIMEOUT'; break }
            $exception = $exception.InnerException
        }
        return [pscustomobject]@{ StatusCode = 0; Code = $code; Data = $null; SessionId = $null }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $buffered.Dispose()
        $request.Dispose()
        $client.Dispose()
        $cancellation.Dispose()
    }
}

function Get-HttpGate {
    param([string]$Name, $Response)
    if ($Response.StatusCode -eq 0) { return New-Gate $Name 'INCONCLUSIVE' $Response.Code }
    if ($Response.StatusCode -lt 200 -or $Response.StatusCode -ge 300) {
        return New-Gate $Name 'FAILED' ('HTTP_{0}' -f $Response.StatusCode)
    }
    if ($Response.Code -ne 'HTTP_RESPONSE') { return New-Gate $Name 'INCONCLUSIVE' $Response.Code }
    if ($null -ne (Get-Field $Response.Data 'error')) { return New-Gate $Name 'FAILED' 'RPC_ERROR' }
    return New-Gate $Name 'PASSED' 'RESPONSE_RECEIVED'
}

function Test-AgentHttpsEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Endpoint,
        [hashtable]$Headers = @{},
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20,
        [ValidateSet('Workstation', 'AzureHost', 'PowerPlatformRuntime', 'Unknown')]
        [string]$ExecutionLocation = 'Workstation',
        [switch]$AllowLoopbackHttp
    )
    Assert-Endpoint $Endpoint -AllowLoopbackHttp:$AllowLoopbackHttp
    $response = Invoke-DiagnosticHttp -Endpoint $Endpoint -Method GET -Headers $Headers -HeadersOnly -TimeoutSeconds $TimeoutSeconds
    $reachability = New-Gate 'HttpsTransport' 'INCONCLUSIVE' $response.Code
    if ($response.StatusCode -gt 0) {
        $reachability = New-Gate 'HttpsTransport' 'PASSED' 'HTTP_RESPONSE_RECEIVED'
        if ($Endpoint.Scheme -eq 'http') { $reachability = New-Gate 'HttpsTransport' 'NOT_TESTED' 'LOOPBACK_HTTP_ONLY' }
    }
    New-Assessment 'Https' $ExecutionLocation @($reachability; (Get-HttpGate 'HttpEndpoint' $response))
}

function Test-AgentMcpServer {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][uri]$Endpoint,
        [hashtable]$Headers = @{},
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20,
        [ValidateRange(1, 20)][int]$MaxPages = 5,
        [ValidateSet('Workstation', 'AzureHost', 'PowerPlatformRuntime', 'Unknown')]
        [string]$ExecutionLocation = 'Workstation',
        [switch]$AllowLoopbackHttp,
        [switch]$AllowToolCall,
        [string]$ToolName,
        [hashtable]$ToolArguments = @{}
    )
    Assert-Endpoint $Endpoint -AllowLoopbackHttp:$AllowLoopbackHttp
    if ($ToolName -and -not $AllowToolCall) { throw 'Tool invocation requires -AllowToolCall and approval.' }
    if ($AllowToolCall -and -not $ToolName) { throw 'Specify an explicitly approved tool name.' }
    $gates = [Collections.Generic.List[object]]::new()
    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    if ($requestHeaders.ContainsKey('Mcp-Session-Id')) { throw 'Sessions must be negotiated, not supplied.' }
    $body = @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
        protocolVersion = '2025-03-26'; capabilities = @{};
        clientInfo = @{ name = 'connectivity-diagnostics'; version = '1.0.0' }
    } }
    $response = Invoke-DiagnosticHttp -Endpoint $Endpoint -Headers $requestHeaders -Body $body -Rpc -RequestId 1 -TimeoutSeconds $TimeoutSeconds
    $gate = Get-HttpGate 'McpInitialize' $response
    $gates.Add($gate)
    if ($gate.Status -eq 'PASSED') {
        $initialization = Get-Field $response.Data 'result'
        if ((Get-Field $initialization 'protocolVersion') -ne '2025-03-26') {
            $gates.Add((New-Gate 'McpVersion' 'INCONCLUSIVE' 'UNSUPPORTED_PROTOCOL_VERSION'))
        }
        elseif ($null -eq (Get-Field (Get-Field $initialization 'capabilities') 'tools')) {
            $gates.Add((New-Gate 'McpTools' 'FAILED' 'TOOLS_CAPABILITY_MISSING'))
        }
        else {
            if ($response.SessionId) { $requestHeaders['Mcp-Session-Id'] = $response.SessionId }
            $body = @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
            $response = Invoke-DiagnosticHttp -Endpoint $Endpoint -Headers $requestHeaders -Body $body -Notification -TimeoutSeconds $TimeoutSeconds
            $gate = Get-HttpGate 'McpInitialized' $response
            $gates.Add($gate)
            if ($gate.Status -eq 'PASSED') {
                $tools = [Collections.Generic.List[object]]::new()
                $cursor = $null
                $listed = $false
                for ($page = 0; $page -lt $MaxPages; $page++) {
                    $parameters = @{}
                    if ($cursor) { $parameters.cursor = $cursor }
                    $requestId = $page + 2
                    $body = @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/list'; params = $parameters }
                    $response = Invoke-DiagnosticHttp -Endpoint $Endpoint -Headers $requestHeaders -Body $body -Rpc -RequestId $requestId -TimeoutSeconds $TimeoutSeconds
                    $gate = Get-HttpGate 'McpToolDiscovery' $response
                    if ($gate.Status -ne 'PASSED') { $gates.Add($gate); break }
                    $result = Get-Field $response.Data 'result'
                    $pageTools = Get-Field $result 'tools'
                    if ($null -eq $pageTools -or $pageTools -isnot [array]) {
                        $gates.Add((New-Gate 'McpToolDiscovery' 'INCONCLUSIVE' 'INVALID_TOOLS_RESULT')); break
                    }
                    foreach ($tool in $pageTools) { $tools.Add($tool) }
                    $cursor = Get-Field $result 'nextCursor'
                    if (-not $cursor) { $listed = $true; break }
                }
                if ($listed) {
                    $code = 'TOOLS_DISCOVERED'
                    $state = 'PASSED'
                    if ($tools.Count -eq 0) { $code = 'NO_TOOLS'; $state = 'FAILED' }
                    $gates.Add((New-Gate 'McpToolDiscovery' $state $code))
                    if ($AllowToolCall) {
                        $matches = @($tools | Where-Object { (Get-Field $_ 'name') -ceq $ToolName })
                        if ($matches.Count -ne 1) { $gates.Add((New-Gate 'McpToolCall' 'FAILED' 'TOOL_NOT_UNIQUE_OR_MISSING')) }
                        elseif ($PSCmdlet.ShouldProcess('configured MCP endpoint', 'Invoke the approved tool; it may change backend state')) {
                            $body = @{ jsonrpc = '2.0'; id = 100; method = 'tools/call'; params = @{ name = $ToolName; arguments = $ToolArguments } }
                            $response = Invoke-DiagnosticHttp -Endpoint $Endpoint -Headers $requestHeaders -Body $body -Rpc -RequestId 100 -TimeoutSeconds $TimeoutSeconds
                            $gate = Get-HttpGate 'McpToolCall' $response
                            if ($gate.Status -eq 'PASSED') {
                                $result = Get-Field $response.Data 'result'
                                if ((Get-Field $result 'isError') -eq $true) { $gate = New-Gate 'McpToolCall' 'FAILED' 'TOOL_REPORTED_ERROR' }
                                else {
                                    $structuredContent = Get-Field $result 'structuredContent'
                                    $hasContent = $null -ne $structuredContent
                                    $contentItems = Get-Field $result 'content'
                                    if ($null -ne $contentItems -and $contentItems -is [array]) {
                                        foreach ($content in $contentItems) {
                                            $contentType = Get-Field $content 'type'
                                            if ($contentType -eq 'text') {
                                                if (-not [string]::IsNullOrWhiteSpace((Get-Field $content 'text'))) { $hasContent = $true }
                                            }
                                            elseif (-not [string]::IsNullOrWhiteSpace([string]$contentType)) {
                                                $hasContent = $true
                                            }
                                        }
                                    }
                                    if (-not $hasContent) { $gate = New-Gate 'McpToolCall' 'FAILED' 'EMPTY_TOOL_CONTENT' }
                                }
                            }
                            $gates.Add($gate)
                        }
                        else { $gates.Add((New-Gate 'McpToolCall' 'NOT_TESTED' 'INVOCATION_NOT_APPROVED')) }
                    }
                }
                elseif ($cursor -and $gate.Status -eq 'PASSED') {
                    $gates.Add((New-Gate 'McpToolDiscovery' 'INCONCLUSIVE' 'PAGINATION_LIMIT'))
                }
            }
        }
    }
    if (-not $AllowToolCall) { $gates.Add((New-Gate 'McpToolCall' 'NOT_TESTED' 'DISCOVERY_ONLY')) }
    New-Assessment 'Mcp' $ExecutionLocation $gates.ToArray()
}

function Test-AgentSearchIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Endpoint,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9_-]{1,127}$')][string]$IndexName,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$SearchText,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')][string]$KeyField,
        [Parameter(Mandatory)][string]$ExpectedKey,
        [ValidateRange(1, 50)][int]$Top = 5,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20,
        [ValidateSet('Workstation', 'AzureHost', 'PowerPlatformRuntime', 'Unknown')]
        [string]$ExecutionLocation = 'Workstation',
        [switch]$AllowLoopbackHttp
    )
    Assert-Endpoint $Endpoint -AllowLoopbackHttp:$AllowLoopbackHttp
    if ($Endpoint.AbsolutePath -ne '/') { throw 'Supply the Search service root endpoint.' }
    $uri = [uri]::new($Endpoint, ("indexes('{0}')/docs/search.post.search?api-version=2024-07-01" -f $IndexName))
    $body = @{ search = $SearchText; top = $Top; select = $KeyField }
    $response = Invoke-DiagnosticHttp -Endpoint $uri -Headers $Headers -Body $body -TimeoutSeconds $TimeoutSeconds
    $gate = Get-HttpGate 'SearchRequest' $response
    $gates = @($gate)
    if ($gate.Status -eq 'PASSED') {
        $documents = Get-Field $response.Data 'value'
        if ($null -eq $documents -or $documents -isnot [array]) {
            $gates += New-Gate 'KnownDocument' 'INCONCLUSIVE' 'INVALID_SEARCH_RESULT'
        }
        else {
            $matches = @($documents | Where-Object { (Get-Field $_ $KeyField) -ceq $ExpectedKey })
            if ($matches.Count -gt 0) { $gates += New-Gate 'KnownDocument' 'PASSED' 'EXPECTED_KEY_FOUND' }
            else { $gates += New-Gate 'KnownDocument' 'FAILED' 'EXPECTED_KEY_NOT_IN_TOP_RESULTS' }
        }
    }
    New-Assessment 'Search' $ExecutionLocation $gates
}

function Get-AgentResponseAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Yes', 'No', 'Unknown')][string]$ToolInvoked,
        [Parameter(Mandatory)][ValidateSet('Success', 'Error', 'Empty', 'Unknown')][string]$BackendOutcome,
        [Parameter(Mandatory)][ValidateSet('Content', 'Empty', 'Unknown')][string]$AgentOutput,
        [Parameter(Mandatory)][ValidateSet('Content', 'Empty', 'Unknown')][string]$ChannelOutput
    )
    $code = 'MORE_EVIDENCE_NEEDED'
    $status = 'INCONCLUSIVE'
    if (($ToolInvoked -eq 'No' -and $BackendOutcome -ne 'Unknown') -or
        ($AgentOutput -eq 'Empty' -and $ChannelOutput -eq 'Content')) { $code = 'CONFLICTING_EVIDENCE' }
    elseif ($ToolInvoked -eq 'No') { $code = 'REVIEW_ORCHESTRATION'; $status = 'FAILED' }
    elseif ($BackendOutcome -eq 'Error') { $code = 'REVIEW_BACKEND_FAILURE'; $status = 'FAILED' }
    elseif ($BackendOutcome -eq 'Empty') { $code = 'REVIEW_RETRIEVAL_OR_TOOL_RESULT'; $status = 'FAILED' }
    elseif ($BackendOutcome -eq 'Success' -and $AgentOutput -eq 'Empty') { $code = 'REVIEW_AGENT_RESPONSE_HANDLING'; $status = 'FAILED' }
    elseif ($AgentOutput -eq 'Content' -and $ChannelOutput -eq 'Empty') { $code = 'REVIEW_CHANNEL_DELIVERY'; $status = 'FAILED' }
    elseif ($ToolInvoked -eq 'Yes' -and $BackendOutcome -eq 'Success' -and $AgentOutput -eq 'Content' -and $ChannelOutput -eq 'Content') {
        $code = 'OBSERVED_CONTENT_AT_ALL_BOUNDARIES'; $status = 'PASSED'
    }
    New-Assessment 'OfflineResponseReview' 'Unknown' @((New-Gate 'EvidenceReview' $status $code))
}

Export-ModuleMember -Function Test-AgentHttpsEndpoint, Test-AgentMcpServer, Test-AgentSearchIndex, Get-AgentResponseAssessment